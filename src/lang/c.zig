const std = @import("std");
const l = @import("../lexer.zig");
const types = @import("../types.zig");
const Spec = types.Spec;
pub fn recover(a: std.mem.Allocator, source: []const u8) !types.Recovery {
    const ts = try l.lex(.c, a, source);
    var out: std.ArrayList(Spec) = .empty;
    var unsupported: std.ArrayList(types.UnsupportedReference) = .empty;
    for (ts, 0..) |token, i| {
        if (!token.is("#") or (i != 0 and ts[i - 1].kind != .newline) or i + 1 >= ts.len or !ts[i + 1].is("include")) continue;
        var name: ?[]const u8 = null;
        var end = i + 2;
        if (end < ts.len and ts[end].kind == .string) {
            name = ts[end].text;
            end += 1;
        } else if (end < ts.len and ts[end].is("<")) {
            const begin = ts[end].end;
            end += 1;
            while (end < ts.len and !ts[end].is(">") and ts[end].kind != .newline) : (end += 1) {}
            if (end < ts.len and ts[end].is(">")) {
                name = source[begin..ts[end].offset];
                end += 1;
            }
        }
        if (name != null and (end == ts.len or ts[end].kind == .newline)) {
            try out.append(a, .{ .name = name.?, .offset = token.offset });
        } else try unsupported.append(a, .{ .offset = token.offset, .expression = .c_include });
    }
    return .{ .specs = try out.toOwnedSlice(a), .unsupported = try unsupported.toOwnedSlice(a) };
}

const p = @import("../path.zig");
pub fn resolve(c: anytype, from: []const u8, spec: Spec) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const a = c.allocator;
    const dir = p.dir(from);
    const name = spec.name;
    if (try c.candidate(dir, name, &.{""})) |v| try out.append(a, v) else {
        for (c.include_roots) |root| if (try c.candidate(root, name, &.{""})) |v| {
            try out.append(a, v);
            break;
        };
    }
    return out.toOwnedSlice(a);
}
pub const extensions = &[_][]const u8{ ".c", ".h", ".cc", ".cpp", ".cxx", ".hpp", ".hh", ".hxx", ".m", ".mm" };
