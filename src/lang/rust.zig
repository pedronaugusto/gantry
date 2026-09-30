const std = @import("std");
const l = @import("../lexer.zig");
const Spec = @import("../types.zig").Spec;
pub fn imports(a: std.mem.Allocator, source: []const u8) ![]const Spec {
    const ts = try l.compact(a, try l.lex(.rust, a, source));
    var out: std.ArrayList(Spec) = .empty;
    for (ts, 0..) |t, i| {
        if (t.is("mod") and i + 2 < ts.len and ts[i + 1].kind == .word and ts[i + 2].is(";")) {
            try out.append(a, .{ .name = ts[i + 1].text, .offset = t.offset, .form = .rust_mod });
        } else if (t.is("use") and i + 1 < ts.len) {
            var j = i + 1;
            try tree(a, ts, &j, "", t.offset, &out);
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
