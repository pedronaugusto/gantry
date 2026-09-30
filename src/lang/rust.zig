const std = @import("std");
const l = @import("../lexer.zig");
const Spec = @import("../types.zig").Spec;
pub fn imports(a: std.mem.Allocator, source: []const u8) ![]const Spec {
    const ts = try l.compact(a, try l.lex(.rust, a, source));
    var out: std.ArrayList(Spec) = .empty;
    const Frame = struct { test_item: bool, scope: []const u8 };
    var frames: std.ArrayList(Frame) = .empty;
    var current: Frame = .{ .test_item = false, .scope = "" };
    var pending_test = false;
    var pending_scope: ?[]const u8 = null;
    var i: usize = 0;
    while (i < ts.len) : (i += 1) {
        const t = ts[i];
        if (t.is("#") and i + 1 < ts.len and (ts[i + 1].is("[") or ts[i + 1].is("!"))) {
            const inner = ts[i + 1].is("!");
            var j = i + 1;
            while (j < ts.len and !ts[j].is("]")) : (j += 1) {}
            const begin = i + (if (inner) @as(usize, 3) else 2);
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
            if (ts[i + 2].is(";")) try out.append(a, .{ .name = ts[i + 1].text, .offset = t.offset, .form = .rust_mod, .kind = if (current.test_item or pending_test) .@"test" else .import, .scope = current.scope });
            if (ts[i + 2].is("{")) pending_scope = try std.mem.join(a, "/", if (current.scope.len == 0) &.{ts[i + 1].text} else &.{ current.scope, ts[i + 1].text });
        } else if (t.is("use") and i + 1 < ts.len) {
            var j = i + 1;
            const start = out.items.len;
            try tree(a, ts, &j, "", t.offset, &out);
            for (out.items[start..]) |*spec| {
                spec.kind = if (current.test_item or pending_test) .@"test" else .import;
                spec.scope = current.scope;
            }
        }
        if (t.is("{")) {
            try frames.append(a, current);
            current = .{ .test_item = current.test_item or pending_test, .scope = pending_scope orelse current.scope };
            pending_test = false;
            pending_scope = null;
        } else if (t.is("}")) {
            if (frames.pop()) |frame| current = frame;
            pending_test = false;
            pending_scope = null;
        } else if (t.is(";")) {
            pending_test = false;
            pending_scope = null;
        }
    }
    return out.toOwnedSlice(a);
}
// Nested use trees are walked on an explicit stack: source nesting never
// consumes the machine's call stack.
fn tree(a: std.mem.Allocator, ts: []const l.Token, j: *usize, _: []const u8, offset: usize, out: *std.ArrayList(Spec)) !void {
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
            try emit(a, path.items, offset, out);
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
    try emit(a, path.items, offset, out);
}
fn emit(a: std.mem.Allocator, name: []const u8, offset: usize, out: *std.ArrayList(Spec)) !void {
    if (std.mem.endsWith(u8, name, "::")) return;
    if (std.mem.startsWith(u8, name, "crate::") or std.mem.startsWith(u8, name, "super::") or std.mem.startsWith(u8, name, "self::"))
        try out.append(a, .{ .name = try a.dupe(u8, name), .offset = offset, .form = .rust_use });
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

pub fn testFile(a: std.mem.Allocator, source: []const u8) !bool {
    const ts = try l.compact(a, try l.lex(.rust, a, source));
    var depth: usize = 0;
    for (ts, 0..) |t, i| {
        if (t.is("{")) depth += 1;
        if (t.is("}") and depth > 0) depth -= 1;
        if (depth == 0 and i + 7 < ts.len and t.is("#") and ts[i + 1].is("!") and ts[i + 2].is("[") and ts[i + 3].is("cfg") and ts[i + 4].is("(") and ts[i + 5].is("test") and ts[i + 6].is(")") and ts[i + 7].is("]")) return true;
    }
    return false;
}
