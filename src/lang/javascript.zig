const std = @import("std");
const l = @import("../lexer.zig");
const Spec = @import("../types.zig").Spec;
pub fn imports(a: std.mem.Allocator, source: []const u8) ![]const Spec {
    const ts = try l.compact(a, try l.lex(.javascript, a, source));
    var out: std.ArrayList(Spec) = .empty;
    for (ts, 0..) |t, i| {
        if (i > 0 and (ts[i - 1].is(".") or ts[i - 1].is("?"))) continue;
        if (t.is("require") or t.is("import")) {
            if (i + 3 < ts.len and ts[i + 1].is("(") and ts[i + 2].kind == .string and (ts[i + 3].is(")") or ts[i + 3].is(","))) {
                try out.append(a, .{ .name = try l.decode(a, ts[i + 2].text), .offset = t.offset });
                continue;
            }
            if (t.is("require")) continue;
            if (i + 1 < ts.len and ts[i + 1].kind == .string) {
                try out.append(a, .{ .name = try l.decode(a, ts[i + 1].text), .offset = t.offset });
                continue;
            }
        } else if (!t.is("export")) continue;
        var j = i + 1;
        while (j < ts.len and !ts[j].is(";") and !ts[j].is("=")) : (j += 1) {
            if (ts[j].is("from") and j + 1 < ts.len and ts[j + 1].kind == .string) {
                try out.append(a, .{ .name = try l.decode(a, ts[j + 1].text), .offset = t.offset });
                break;
            }
            if (ts[j].is("import") or ts[j].is("export")) break;
        }
    }
    return out.toOwnedSlice(a);
}
