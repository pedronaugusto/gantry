const std = @import("std");
const l = @import("../lexer.zig");
const types = @import("../types.zig");
const Spec = types.Spec;
/// The token stream recovery reads; `seen` observes it as it grows.
pub fn lex(a: std.mem.Allocator, source: []const u8, seen: ?l.Observer) ![]const l.Token {
    return l.lexCompact(.rust, a, source, seen);
}
pub fn recover(a: std.mem.Allocator, source: []const u8) !types.Recovery {
    return recoverTokens(a, source, try lex(a, source, null));
}
pub fn recoverTokens(a: std.mem.Allocator, _: []const u8, ts: []const l.Token) !types.Recovery {
    var out: std.ArrayList(Spec) = .empty;
    var unsupported: std.ArrayList(types.UnsupportedReference) = .empty;
    const Frame = struct { test_item: bool, scope: []const u8 };
    var frames: std.ArrayList(Frame) = .empty;
    var current: Frame = .{ .test_item = false, .scope = "" };
    var pending_test = false;
    var pending_path = false;
    var pending_scope: ?[]const u8 = null;
    var names: Names = .{ .ts = ts };
    // A crate a path names once per file and kind.
    var crates: std.StringHashMapUnmanaged(void) = .empty;
    var test_crates: std.StringHashMapUnmanaged(void) = .empty;
    var i: usize = 0;
    while (i < ts.len) : (i += 1) {
        const t = ts[i];
        // A word before `:` may start a crate path; `extern` before `crate`
        // names one. Other tokens skip both.
        if (t.kind == .word and i + 2 < ts.len and (ts[i + 1].text[0] == ':' or t.text.len == "extern".len)) {
            const testing = current.test_item or pending_test;
            const seen = if (testing) &test_crates else &crates;
            const like: Spec = .{ .name = "", .offset = 0, .kind = if (testing) .@"test" else .import, .scope = current.scope };
            if (ts[i + 1].kind == .punctuation) {
                if (crateRoot(ts, i) and !(try names.get(a)).all.contains(t.text)) try noteCrate(a, t, seen, like, &out);
            } else if (t.is("extern") and ts[i + 1].is("crate") and ts[i + 2].kind == .word and !ts[i + 2].is("self")) {
                var spec = like;
                spec.name = ts[i + 2].text;
                spec.offset = t.offset;
                spec.form = .rust_crate;
                try out.append(a, spec);
                try seen.put(a, ts[i + 2].text, {});
            }
        }
        if (t.is("include") and i + 2 < ts.len and ts[i + 1].is("!") and (ts[i + 2].is("(") or ts[i + 2].is("{") or ts[i + 2].is("[")))
            try unsupported.append(a, .{ .offset = t.offset, .expression = .rust_include });
        if (t.is("#") and i + 1 < ts.len and (ts[i + 1].is("[") or ts[i + 1].is("!"))) {
            const inner = ts[i + 1].is("!");
            var j = i + 1;
            while (j < ts.len and !ts[j].is("]")) : (j += 1) {}
            const begin = i + (if (inner) @as(usize, 3) else 2);
            // `#[tokio::main]`, `#[derive(serde::Serialize)]`.
            for (i + 1..j) |k| if (crateRoot(ts, k) and !(try names.get(a)).all.contains(ts[k].text)) try noteCrate(a, ts[k], if (current.test_item) &test_crates else &crates, .{ .name = "", .offset = 0, .kind = if (current.test_item) .@"test" else .import, .scope = current.scope }, &out);
            if (begin < j and ts[begin].is("path")) {
                try unsupported.append(a, .{ .offset = t.offset, .expression = .rust_path });
                pending_path = true;
            }
            // Only an explicit cfg(test) is proof; cfg(not(test)) and cfg_attr
            // remain ordinary lexical items, without guessed evaluation.
            if (begin + 3 < j and ts[begin].is("cfg") and ts[begin + 1].is("(") and ts[begin + 2].is("test") and ts[begin + 3].is(")")) {
                if (inner) current.test_item = true else pending_test = true;
            }
            i = j;
            continue;
        }
        if (t.is("mod") and i + 2 < ts.len and ts[i + 1].kind == .word) {
            if (ts[i + 1].is("tests")) pending_test = true;
            if (ts[i + 2].is(";") and !pending_path) try out.append(a, .{ .name = ts[i + 1].text, .offset = t.offset, .form = .rust_mod, .kind = if (current.test_item or pending_test) .@"test" else .import, .scope = current.scope });
            if (ts[i + 2].is("{")) pending_scope = try std.mem.join(a, "/", if (current.scope.len == 0) &.{ts[i + 1].text} else &.{ current.scope, ts[i + 1].text });
        } else if (t.is("use") and i + 1 < ts.len) {
            var j = i + 1;
            const start = out.items.len;
            try tree(a, ts, &j, &names, current.scope, t.offset, &out);
            for (out.items[start..]) |*spec| {
                spec.kind = if (current.test_item or pending_test) .@"test" else .import;
                spec.scope = current.scope;
            }
        }
        if (t.is("{")) {
            try frames.append(a, current);
            current = .{ .test_item = current.test_item or pending_test, .scope = pending_scope orelse current.scope };
            pending_test = false;
            pending_path = false;
            pending_scope = null;
        } else if (t.is("}")) {
            if (frames.pop()) |frame| current = frame;
            pending_test = false;
            pending_path = false;
            pending_scope = null;
        } else if (t.is(";")) {
            pending_test = false;
            pending_path = false;
            pending_scope = null;
        }
    }
    return .{ .specs = try out.toOwnedSlice(a), .unsupported = try unsupported.toOwnedSlice(a) };
}
// Nested use trees are walked on an explicit stack: source nesting never
// consumes the machine's call stack.
fn tree(a: std.mem.Allocator, ts: []const l.Token, j: *usize, names: *Names, scope: []const u8, offset: usize, out: *std.ArrayList(Spec)) !void {
    var prefixes: std.ArrayList([]const u8) = .empty;
    var path: std.ArrayList(u8) = .empty;
    while (j.* < ts.len) : (j.* += 1) {
        const t = ts[j.*];
        if (t.is(";")) break;
        if (t.is("{")) {
            try prefixes.append(a, try a.dupe(u8, path.items));
            continue;
        }
        if (t.is(",") or t.is("}")) {
            try emit(a, path.items, names, scope, offset, out);
            if (t.is("}") and prefixes.items.len > 0) _ = prefixes.pop();
            path.clearRetainingCapacity();
            if (prefixes.getLastOrNull()) |prefix| try path.appendSlice(a, prefix);
            continue;
        }
        if (t.is("as")) {
            j.* += 1;
            continue;
        }
        if (t.kind == .word or t.is(":") or t.is("*")) try path.appendSlice(a, t.text) else break;
    }
    try emit(a, path.items, names, scope, offset, out);
}
fn emit(a: std.mem.Allocator, raw: []const u8, names: *Names, scope: []const u8, offset: usize, out: *std.ArrayList(Spec)) !void {
    if (raw.len == 0 or std.mem.endsWith(u8, raw, "::")) return;
    if (std.mem.startsWith(u8, raw, "crate::") or std.mem.startsWith(u8, raw, "super::") or std.mem.startsWith(u8, raw, "self::")) {
        try out.append(a, .{ .name = try a.dupe(u8, raw), .offset = offset, .form = .rust_use });
        return;
    }
    // `::serde::X` names a crate whatever this module declares.
    const global = std.mem.startsWith(u8, raw, "::");
    const name = if (global) raw[2..] else raw;
    const root = name[0 .. std.mem.find(u8, name, "::") orelse name.len];
    if (!crateName(root)) return;
    if (!global) {
        const found = try names.get(a);
        const key = try std.fmt.allocPrint(a, "{s}\x00{s}", .{ scope, root });
        // A module this module declares is what a 2018 `use` path names
        // first, as rustc resolves it, unless an `extern crate` here takes
        // the same name: rustc refuses both (E0260), and so no edge.
        if (found.declared.get(key)) |place| {
            // An inline module is this file; a `#[path]` one is not read.
            if (place != .file) return;
            if (!found.externs.contains(key)) {
                try out.append(a, .{ .name = try a.dupe(u8, name), .offset = offset, .form = .rust_use });
                return;
            }
        }
        // A module declared in another module is not in scope here: the
        // name is an extern crate's, as rustc reads it.
    }
    try out.append(a, .{ .name = try a.dupe(u8, name), .offset = offset, .form = .rust_crate });
}
/// A crate a path names, once per file and kind: `like` gives its kind
/// and scope.
fn noteCrate(a: std.mem.Allocator, t: l.Token, seen: *std.StringHashMapUnmanaged(void), like: Spec, out: *std.ArrayList(Spec)) !void {
    const entry = try seen.getOrPut(a, t.text);
    if (entry.found_existing) return;
    var spec = like;
    spec.name = t.text;
    spec.offset = t.offset;
    spec.form = .rust_crate;
    try out.append(a, spec);
}
/// The names a file brings into scope: its modules, every word of its
/// `use` trees, and `extern crate` aliases. A path rooted at one is local.
/// Gathered on the first path that could name a crate.
const Names = struct {
    ts: []const l.Token,
    found: ?Found = null,
    const Found = struct {
        all: std.StringHashMapUnmanaged(void),
        modules: std.StringHashMapUnmanaged(void),
        /// Modules by `scope\x00name`, and where their items are.
        declared: std.StringHashMapUnmanaged(enum { file, here, path_attribute }),
        /// `extern crate` names, or their aliases, by `scope\x00name`.
        externs: std.StringHashMapUnmanaged(void),
    };
    fn get(self: *Names, a: std.mem.Allocator) !*const Found {
        if (self.found == null) {
            const ts = self.ts;
            var all: std.StringHashMapUnmanaged(void) = .empty;
            var modules: std.StringHashMapUnmanaged(void) = .empty;
            var declared: @FieldType(Found, "declared") = .empty;
            var externs: std.StringHashMapUnmanaged(void) = .empty;
            // Module scopes as recovery tracks them: only `mod name {` opens one.
            var scopes: std.ArrayList([]const u8) = .empty;
            var scope: []const u8 = "";
            var pending: ?[]const u8 = null;
            var i: usize = 0;
            while (i < ts.len) : (i += 1) {
                if (ts[i].is("mod") and i + 1 < ts.len and ts[i + 1].kind == .word) {
                    const name = ts[i + 1].text;
                    try modules.put(a, name, {});
                    try all.put(a, name, {});
                    const inline_body = i + 2 < ts.len and ts[i + 2].is("{");
                    try declared.put(a, try std.fmt.allocPrint(a, "{s}\x00{s}", .{ scope, name }), if (inline_body) .here else if (pathAttribute(ts, i)) .path_attribute else .file);
                    if (i + 2 < ts.len and ts[i + 2].is("{")) pending = try std.mem.join(a, "/", if (scope.len == 0) &.{name} else &.{ scope, name });
                } else if (ts[i].is("use")) {
                    while (i < ts.len and !ts[i].is(";")) : (i += 1) if (ts[i].kind == .word) try all.put(a, ts[i].text, {});
                } else if (ts[i].is("extern") and i + 2 < ts.len and ts[i + 1].is("crate") and ts[i + 2].kind == .word) {
                    const alias = i + 4 < ts.len and ts[i + 3].is("as") and ts[i + 4].kind == .word;
                    const name = ts[i + (if (alias) @as(usize, 4) else 2)].text;
                    if (alias) try all.put(a, name, {});
                    try externs.put(a, try std.fmt.allocPrint(a, "{s}\x00{s}", .{ scope, name }), {});
                } else if (ts[i].is("{")) {
                    try scopes.append(a, scope);
                    scope = pending orelse scope;
                    pending = null;
                } else if (ts[i].is("}")) {
                    scope = scopes.pop() orelse "";
                    pending = null;
                } else if (ts[i].is(";")) pending = null;
            }
            self.found = .{ .all = all, .modules = modules, .declared = declared, .externs = externs };
        }
        return &self.found.?;
    }
};
/// Whether `#[path = ...]` stands right before the `mod` at `i`.
fn pathAttribute(ts: []const l.Token, i: usize) bool {
    if (i == 0 or !ts[i - 1].is("]")) return false;
    var k = i - 1;
    while (k > 0 and !ts[k].is("[")) k -= 1;
    return k + 1 < i and ts[k + 1].is("path");
}
/// A word a path starts with, `name::`, that could name a crate: not
/// after `::`, `.` or `$`, and not a function called with `::<`. The
/// caller rules out names the file brought in itself.
fn crateRoot(ts: []const l.Token, i: usize) bool {
    const t = ts[i];
    // `::` first: most words are not followed by one.
    if (i + 3 >= ts.len or ts[i + 1].offset != t.end or !ts[i + 1].is(":") or !ts[i + 2].is(":") or ts[i + 2].offset != ts[i + 1].end) return false;
    // Inside a path, after a method's `.`, or in a macro's `$crate`.
    if (i > 0 and ts[i - 1].kind == .punctuation and std.mem.findScalar(u8, ":.$", ts[i - 1].text[0]) != null) return false;
    if (ts[i + 3].is("<")) return false;
    return t.kind == .word and crateName(t.text);
}
/// A crate's name as code spells it: lower case or `_` first, and not a
/// keyword a path can start with.
fn crateName(word: []const u8) bool {
    if (word.len == 0 or !(std.ascii.isLower(word[0]) or word[0] == '_')) return false;
    if (word[0] != 'c' and word[0] != 's' and word[0] != 'r') return true;
    for ([_][]const u8{ "crate", "self", "super", "r#crate" }) |keyword| if (std.mem.eql(u8, word, keyword)) return false;
    return true;
}

const p = @import("../path.zig");
pub fn resolve(c: anytype, from: []const u8, spec: Spec) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const a = c.allocator;
    const dir = p.dir(from);
    const name = spec.name;
    var root = dir;
    while (root.len > 0 and !std.mem.eql(u8, p.base(root), "src")) root = p.dir(root);
    const filename = p.base(from);
    var module_dir = dir;
    if (!std.mem.eql(u8, filename, "mod.rs") and !std.mem.eql(u8, filename, "lib.rs") and !std.mem.eql(u8, filename, "main.rs")) module_dir = from[0 .. from.len - 3];
    if (spec.scope.len > 0) module_dir = try std.mem.join(a, "/", &.{ module_dir, spec.scope });
    if (spec.form == .rust_crate) return &.{};
    if (spec.form == .rust_mod) {
        if (try c.candidate(module_dir, name, &.{ ".rs", "/mod.rs" })) |v| try out.append(a, v);
    } else {
        var s = name;
        var base_dir = module_dir;
        if (std.mem.startsWith(u8, s, "crate::")) {
            base_dir = root;
            s = s[7..];
        } else if (std.mem.startsWith(u8, s, "self::")) s = s[6..] else while (std.mem.startsWith(u8, s, "super::")) {
            base_dir = p.dir(base_dir);
            s = s[7..];
        }
        var rel: []const u8 = try std.mem.replaceOwned(u8, a, s, "::", "/");
        while (rel.len > 0) {
            if (try c.candidate(base_dir, rel, &.{ ".rs", "/mod.rs" })) |v| {
                try out.append(a, v);
                break;
            }
            rel = p.dir(rel);
        }
    }
    return out.toOwnedSlice(a);
}
pub const extensions = &[_][]const u8{".rs"};

pub fn testFileTokens(ts: []const l.Token) bool {
    var depth: usize = 0;
    for (ts, 0..) |t, i| {
        if (t.is("{")) depth += 1;
        if (t.is("}") and depth > 0) depth -= 1;
        if (depth == 0 and i + 7 < ts.len and t.is("#") and ts[i + 1].is("!") and ts[i + 2].is("[") and ts[i + 3].is("cfg") and ts[i + 4].is("(") and ts[i + 5].is("test") and ts[i + 6].is(")") and ts[i + 7].is("]")) return true;
    }
    return false;
}
