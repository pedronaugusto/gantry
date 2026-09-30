const std = @import("std");
const l = @import("../lexer.zig");
const Spec = @import("../types.zig").Spec;
pub fn imports(a: std.mem.Allocator, source: []const u8) ![]const Spec {
    const ts = try l.compact(a, try l.lex(.zig, a, source));
    var out: std.ArrayList(Spec) = .empty;
    var aliases: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (ts, 0..) |t, i| {
        if (!t.is("@") or i + 4 >= ts.len or !ts[i + 1].is("import") or !ts[i + 2].is("(") or ts[i + 3].kind != .string or !ts[i + 4].is(")")) continue;
        const name = try std.zig.string_literal.parseAlloc(a, source[ts[i + 3].offset..ts[i + 3].end]);
        try out.append(a, .{ .name = name, .offset = t.offset });
        if (i + 6 < ts.len and ts[i + 5].is(".") and ts[i + 6].kind == .word)
            try out.append(a, .{ .name = name, .member = ts[i + 6].text, .offset = t.offset });
        // const/var alias [: type] = @import(...); as used by layering checks.
        if (i > 0 and ts[i - 1].is("=")) {
            var j = i - 1;
            while (j > 0 and !ts[j - 1].is(";") and !ts[j - 1].is("{") and !ts[j - 1].is("}")) : (j -= 1) {}
            if (j + 1 < i and (ts[j].is("const") or ts[j].is("var")) and ts[j + 1].kind == .word and i + 5 < ts.len and ts[i + 5].is(";"))
                try aliases.put(a, ts[j + 1].text, name);
        }
    }
    for (ts, 0..) |t, i| {
        if (t.kind != .word or i + 2 >= ts.len or !ts[i + 1].is(".") or ts[i + 2].kind != .word) continue;
        if (i > 0 and ts[i - 1].is(".")) continue;
        if (aliases.get(t.text)) |name| try out.append(a, .{ .name = name, .member = ts[i + 2].text, .offset = t.offset });
    }
    return out.toOwnedSlice(a);
}

const p = @import("../path.zig");
pub fn resolve(c: anytype, from: []const u8, spec: Spec) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const a = c.allocator;
    const dir = p.dir(from);
    const name = spec.name;
    if (std.mem.endsWith(u8, name, ".zig")) {
        if (try c.candidate(dir, name, &.{""})) |v| try out.append(a, v);
    } else for (c.named_modules) |m| {
        if (std.mem.eql(u8, name, m.name) and @import("../rules.zig").matches(m.from, from)) {
            if (try c.candidate("", m.path, &.{""})) |v| try out.append(a, v);
            break;
        }
    }
    return out.toOwnedSlice(a);
}
pub const extensions = &[_][]const u8{".zig"};
