const std = @import("std");
const l = @import("../lexer.zig");
const Spec = @import("../types.zig").Spec;
pub fn imports(a: std.mem.Allocator, source: []const u8) ![]const Spec {
    const ts = try l.lex(.c, a, source);
    var out: std.ArrayList(Spec) = .empty;
    for (ts, 0..) |t, i| {
        if (!t.is("#") or (i != 0 and ts[i - 1].kind != .newline) or i + 2 >= ts.len or !ts[i + 1].is("include")) continue;
        if (ts[i + 2].kind == .string) {
            try out.append(a, .{ .name = ts[i + 2].text, .offset = t.offset });
        } else if (ts[i + 2].is("<")) {
            var end = i + 3;
            while (end < ts.len and !ts[end].is(">") and ts[end].kind != .newline) : (end += 1) {}
            if (end < ts.len and ts[end].is(">")) try out.append(a, .{ .name = source[ts[i + 2].end..ts[end].offset], .offset = t.offset });
        }
    }
    return out.toOwnedSlice(a);
}
