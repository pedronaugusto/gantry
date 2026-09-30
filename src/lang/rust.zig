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
            if (prefixes.getLastOrNull()) |p| try path.appendSlice(a, p);
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
