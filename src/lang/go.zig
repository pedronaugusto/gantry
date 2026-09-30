const std = @import("std");
const l = @import("../lexer.zig");
const Spec = @import("../types.zig").Spec;
pub fn imports(a: std.mem.Allocator, source: []const u8) ![]const Spec {
    const ts = try l.compact(a, try l.lex(.go, a, source));
    var out: std.ArrayList(Spec) = .empty;
    for (ts, 0..) |t, i| {
        if (!t.is("import") or i + 1 >= ts.len) continue;
        var j = i + 1;
        const block = ts[j].is("(");
        if (block) j += 1;
        while (j < ts.len and !ts[j].is(")")) : (j += 1) {
            if (ts[j].kind == .string) {
                const raw = source[ts[j].offset] == '`';
                try out.append(a, .{ .name = if (raw) ts[j].text else try l.decode(a, ts[j].text), .offset = t.offset });
                if (!block) break;
            } else if (!block and ts[j].kind != .word and !ts[j].is(".")) break;
        }
    }
    return out.toOwnedSlice(a);
}

const p = @import("../path.zig");
pub fn resolve(c: anytype, from: []const u8, spec: Spec) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const a = c.allocator;
    const name = spec.name;
    var owner: ?@import("../resolve.zig").GoModule = null;
    for (c.go_modules) |m| if (p.within(m.root, from) and (owner == null or m.root.len > owner.?.root.len)) {
        owner = m;
    };
    const m = owner orelse return &.{};
    if (!p.within(m.name, name)) return &.{};
    const tail = if (name.len == m.name.len) "" else name[m.name.len + 1 ..];
    const joined = try std.fmt.allocPrint(a, "{s}/{s}", .{ m.root, tail });
    const key = try p.normalize(a, if (m.root.len == 0) joined[1..] else joined);
    // A nested module is its own compilation boundary.
    for (c.go_modules) |other| if (other.root.len > m.root.len and p.within(other.root, key)) return &.{};
    if (c.packages.get(key)) |files| try out.appendSlice(a, files.items);
    return out.toOwnedSlice(a);
}
pub const extensions = &[_][]const u8{".go"};
