const std = @import("std");
const l = @import("../lexer.zig");
const types = @import("../types.zig");
const Spec = types.Spec;
/// The token stream recovery reads; `seen` observes it as it grows.
pub fn lex(a: std.mem.Allocator, source: []const u8, seen: ?l.Observer) ![]const l.Token {
    return l.lexSeen(.nim, a, source, seen);
}
pub fn recover(a: std.mem.Allocator, source: []const u8) !types.Recovery {
    return recoverTokens(a, source, try lex(a, source, null));
}
/// `import`, `include` and `from … import` statements name modules by path:
/// `a/b`, `std / os`, `../a`, `"a/b"`, `"."/a` and groups `a/[b, c]`. Symbols after
/// `from … import` and `except` are not modules. An operand that is not a
/// path, a group or a plain string is unsupported.
pub fn recoverTokens(a: std.mem.Allocator, _: []const u8, ts: []const l.Token) !types.Recovery {
    var out: std.ArrayList(Spec) = .empty;
    var unsupported: std.ArrayList(types.UnsupportedReference) = .empty;
    var i: usize = 0;
    while (i < ts.len) : (i += 1) {
        const t = ts[i];
        const from = t.is("from");
        if (!from and !t.is("import") and !t.is("include")) continue;
        // A statement starts a line or follows `;` or a `when`/`else` colon.
        if (i > 0 and ts[i - 1].kind != .newline and !ts[i - 1].is(";") and !ts[i - 1].is(":")) continue;
        const expression: types.ImportExpression = if (t.is("include")) .nim_include else .nim_import;
        var j = i + 1;
        const before = out.items.len;
        const literal = while (true) {
            if (!try module(a, ts, &j, t.offset, &out)) break false;
            // A pragma such as `{.all.}` and an alias belong to the module.
            if (j < ts.len and ts[j].is("{")) {
                while (j < ts.len and !ts[j].is("}") and ts[j].kind != .newline) : (j += 1) {}
                if (j < ts.len and ts[j].is("}")) j += 1;
            }
            alias(ts, &j);
            if (from) break j < ts.len and ts[j].is("import");
            if (j < ts.len and ts[j].is("except")) break true;
            if (j < ts.len and ts[j].is(",")) {
                j += 1;
                while (j < ts.len and ts[j].kind == .newline) : (j += 1) {}
                continue;
            }
            break j == ts.len or ts[j].kind == .newline or ts[j].is(";");
        };
        if (!literal) {
            // An unreadable statement contributes no guessed module.
            out.shrinkRetainingCapacity(before);
            try unsupported.append(a, .{ .offset = t.offset, .expression = expression });
        }
        i = j -| 1;
    }
    return .{ .specs = try out.toOwnedSlice(a), .unsupported = try unsupported.toOwnedSlice(a) };
}
/// One module operand, which a bracket group expands into several.
fn module(a: std.mem.Allocator, ts: []const l.Token, j: *usize, offset: usize, out: *std.ArrayList(Spec)) !bool {
    // The operand list can start on the next, indented line.
    while (j.* < ts.len and ts[j.*].kind == .newline) : (j.* += 1) {}
    const prefix = (try path(a, ts, j)) orelse return false;
    if (prefix.len == 0) return false;
    if (!std.mem.endsWith(u8, prefix, "/") or j.* >= ts.len or !ts[j.*].is("[")) {
        if (std.mem.endsWith(u8, prefix, "/")) return false;
        try out.append(a, .{ .name = prefix, .offset = offset });
        return true;
    }
    j.* += 1;
    while (true) {
        while (j.* < ts.len and ts[j.*].kind == .newline) : (j.* += 1) {}
        // A group can end with a trailing comma.
        if (j.* < ts.len and ts[j.*].is("]") and out.items.len > 0) {
            j.* += 1;
            return true;
        }
        const member = (try path(a, ts, j)) orelse return false;
        if (member.len == 0 or std.mem.endsWith(u8, member, "/")) return false;
        try out.append(a, .{ .name = try std.mem.concat(a, u8, &.{ prefix, member }), .offset = offset });
        alias(ts, j);
        while (j.* < ts.len and ts[j.*].kind == .newline) : (j.* += 1) {}
        if (j.* < ts.len and ts[j.*].is(",")) {
            j.* += 1;
            continue;
        }
        if (j.* < ts.len and ts[j.*].is("]")) {
            j.* += 1;
            return true;
        }
        return false;
    }
}
fn alias(ts: []const l.Token, j: *usize) void {
    if (j.* + 1 < ts.len and ts[j.*].is("as") and ts[j.* + 1].kind == .word) j.* += 2;
}
/// Names and strings joined by `/`, with leading `.` and `..` components:
/// `a/b`, `std / os`, `../a`, `"a/b"`, `"."/x`, and `a.b` for `a/b`. Null
/// for an undecodable string.
fn path(a: std.mem.Allocator, ts: []const l.Token, j: *usize) !?[]const u8 {
    var name: std.ArrayList(u8) = .empty;
    var last: enum { none, word, dot, slash } = .none;
    while (j.* < ts.len) : (j.* += 1) {
        const t = ts[j.*];
        if (t.is("/")) {
            if (last != .word and last != .dot) break;
            last = .slash;
        } else if (t.is(".")) {
            // `a.b` is the deprecated spelling of `a/b`.
            if (last == .word) {
                if (j.* + 1 >= ts.len or ts[j.* + 1].kind != .word) break;
                last = .slash;
                try name.append(a, '/');
                continue;
            }
            last = .dot;
        } else if (t.kind == .string and (last == .none or last == .slash)) {
            last = .word;
            try name.appendSlice(a, l.decode(a, t.text) catch |err| switch (err) {
                error.InvalidEscape => return null,
                else => return err,
            });
            continue;
        } else if (t.kind == .word and (last == .none or last == .slash) and !t.is("as") and !t.is("except") and !t.is("import")) {
            last = .word;
        } else break;
        try name.appendSlice(a, t.text);
    }
    const value = try name.toOwnedSlice(a);
    return value;
}

const p = @import("../path.zig");
/// Nim's own order (`findModule`): `std/` names only the standard library,
/// `pkg/` only search paths; any other name is first beside the importing
/// file, then, unless it starts with a dot, on the search paths. A name
/// without an extension is a `.nim` file.
pub fn resolve(c: anytype, from: []const u8, spec: Spec) ![]const []const u8 {
    const a = c.allocator;
    var name = spec.name;
    if (std.mem.startsWith(u8, name, "std/")) return &.{};
    const suffix: []const u8 = if (std.fs.path.extension(p.base(name)).len == 0) ".nim" else "";
    const package = std.mem.startsWith(u8, name, "pkg/");
    if (package) name = name[4..];
    if (!package) {
        if (try c.candidate(p.dir(from), name, &.{suffix})) |v| return a.dupe([]const u8, &.{v});
        if (name[0] == '.') return &.{};
    }
    // Nim inserts every `--path` first, so nearer configs and later lines win.
    var configs = std.mem.reverseIterator(c.nim_configs);
    while (configs.next()) |config| {
        if (!p.within(config.dir, from)) continue;
        var paths = std.mem.reverseIterator(config.paths);
        while (paths.next()) |root| if (try c.candidate(root, name, &.{suffix})) |v| return a.dupe([]const u8, &.{v});
    }
    return &.{};
}
pub const extensions = &[_][]const u8{".nim"};
