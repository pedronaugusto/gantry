const check_module = @import("../rules/check.zig");
const std = @import("std");
const l = @import("../lexer.zig");
const liveness = @import("zig/liveness.zig");
const types = @import("../types.zig");
const Spec = types.Spec;
/// The token stream recovery reads; `seen` observes it as it grows.
pub fn lex(a: std.mem.Allocator, source: []const u8, seen: ?l.Observer) ![]const l.Token {
    return l.lexCompact(.zig, a, source, seen);
}
pub fn recover(a: std.mem.Allocator, source: []const u8) !types.Recovery {
    return recoverTokens(a, source, try lex(a, source, null));
}
pub fn recoverTokens(a: std.mem.Allocator, source: []const u8, ts: []const l.Token) !types.Recovery {
    var out: std.ArrayList(Spec) = .empty;
    // The token of each spec, which says whether only tests reach it.
    var where: std.ArrayList(u32) = .empty;
    var unsupported: std.ArrayList(types.UnsupportedReference) = .empty;
    var aliases: std.StringHashMapUnmanaged([]const u8) = .empty;
    const shape = try liveness.Shape.read(a, ts);
    for (shape.imports) |index| {
        const i: usize = index;
        const t = ts[i];
        if (i + 4 >= ts.len or !ts[i + 2].is("(") or ts[i + 3].kind != .string or !ts[i + 4].is(")")) {
            try unsupported.append(a, .{ .offset = t.offset, .expression = .zig_import });
            continue;
        }
        // Without an escape or a line break a literal is its own value.
        const plain = std.mem.indexOfAny(u8, ts[i + 3].text, "\\\n") == null;
        const name = if (plain) ts[i + 3].text else try std.zig.string_literal.parseAlloc(a, source[ts[i + 3].offset..ts[i + 3].end]);
        try out.append(a, .{ .name = name, .offset = t.offset });
        try where.append(a, index);
        if (i + 6 < ts.len and ts[i + 5].is(".") and ts[i + 6].kind == .word) {
            try out.append(a, .{ .name = name, .member = ts[i + 6].text, .offset = t.offset });
            try where.append(a, index);
        }
        // const/var alias [: type] = @import(...); as used by layering checks.
        // The `;` comes first: it bounds the walk back to the declaration.
        if (i > 0 and ts[i - 1].is("=") and i + 5 < ts.len and ts[i + 5].is(";")) {
            var j = i - 1;
            while (j > 0 and !ts[j - 1].is(";") and !ts[j - 1].is("{") and !ts[j - 1].is("}")) : (j -= 1) {}
            if (j + 1 < i and (ts[j].is("const") or ts[j].is("var")) and ts[j + 1].kind == .word)
                try aliases.put(a, ts[j + 1].text, name);
        }
    }
    // One pass over the words: references between declarations, and the
    // members an alias reaches.
    var words = if (out.items.len > 0) try liveness.Words.init(a, ts, shape) else null;
    if (words != null) for (ts, 0..) |t, i| {
        if (t.kind == .string) try words.?.see(i);
        if (t.kind != .word) continue;
        try words.?.see(i);
        if (i + 2 >= ts.len or !ts[i + 1].is(".") or ts[i + 2].kind != .word) continue;
        if (i > 0 and ts[i - 1].is(".")) continue;
        if (aliases.get(t.text)) |name| {
            try out.append(a, .{ .name = name, .member = ts[i + 2].text, .offset = t.offset });
            try where.append(a, @intCast(i));
        }
    };
    if (words) |*w| try w.classify(out.items, where.items);
    return .{ .specs = try out.toOwnedSlice(a), .unsupported = try unsupported.toOwnedSlice(a) };
}

const p = @import("../path.zig");
pub fn resolve(c: anytype, from: []const u8, spec: Spec) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const a = c.allocator;
    const dir = p.dir(from);
    const name = spec.name;
    // A `.zig` or `.zon` name is a file beside the importer; any other a module.
    if (std.mem.endsWith(u8, name, ".zig") or std.mem.endsWith(u8, name, ".zon")) {
        if (try c.candidate(dir, name, &.{""})) |v| try out.append(a, v);
    } else for (c.named_modules) |m| {
        if (std.mem.eql(u8, name, m.name) and check_module.matches(m.from, from)) {
            if (try c.candidate("", m.path, &.{""})) |v| try out.append(a, v);
            break;
        }
    }
    return out.toOwnedSlice(a);
}
pub const extensions = &[_][]const u8{".zig"};
