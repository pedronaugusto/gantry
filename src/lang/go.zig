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
