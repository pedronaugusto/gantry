const std = @import("std");
const l = @import("../lexer.zig");
const liveness = @import("zig/liveness.zig");
const types = @import("../types.zig");
const Spec = types.Spec;
/// The token stream recovery reads; `seen` observes it as it grows.
pub fn lex(arena: std.mem.Allocator, source: []const u8, seen: ?l.Observer) std.mem.Allocator.Error![]const l.Token {
    return l.lexCompact(.zig, arena, source, seen);
}
pub fn recover(arena: std.mem.Allocator, source: []const u8) error{ InvalidLiteral, OutOfMemory }!types.Recovery {
    return recoverSeen(arena, source, null);
}
pub fn recoverTokens(arena: std.mem.Allocator, source: []const u8, ts: []const l.Token) error{ InvalidLiteral, OutOfMemory }!types.Recovery {
    return recoverShaped(arena, source, ts, try liveness.Shape.read(arena, ts));
}
/// Recover while collecting structure in the lexer's emission pass.
pub fn recoverSeen(arena: std.mem.Allocator, source: []const u8, seen: ?l.Observer) error{ InvalidLiteral, OutOfMemory }!types.Recovery {
    // Short files keep a smaller builder; every list still spills on overflow.
    return if (source.len <= 1024) recoverBuilt(true, arena, source, seen) else recoverBuilt(false, arena, source, seen);
}
fn recoverBuilt(comptime small: bool, arena: std.mem.Allocator, source: []const u8, seen: ?l.Observer) error{ InvalidLiteral, OutOfMemory }!types.Recovery {
    var builder: liveness.Builder(true, small) = .{};
    const ts = try l.lexCompactWith(.zig, liveness.Builder(true, small), arena, source, seen, &builder);
    return recoverShaped(arena, source, ts, try builder.finish(arena, ts));
}
fn recoverShaped(arena: std.mem.Allocator, source: []const u8, ts: []const l.Token, shape: liveness.Shape) error{ InvalidLiteral, OutOfMemory }!types.Recovery {
    var out: std.ArrayList(Spec) = .empty;
    // The token of each spec, which says whether only tests reach it.
    var where: std.ArrayList(u32) = .empty;
    var unsupported: std.ArrayList(types.UnsupportedReference) = .empty;
    var aliases: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (shape.imports) |index| {
        const i: usize = index;
        const t = ts[i];
        if (i + 4 >= ts.len or !ts[i + 2].is("(") or ts[i + 3].kind != .string or !ts[i + 4].is(")")) {
            try unsupported.append(arena, .{ .offset = t.offset, .expression = .zig_import });
            continue;
        }
        // Without an escape or a line break a literal is its own value.
        const plain = std.mem.findAny(u8, ts[i + 3].text, "\\\n") == null;
        const name = if (plain) ts[i + 3].text else try std.zig.string_literal.parseAlloc(arena, source[ts[i + 3].offset..ts[i + 3].end]);
        try out.append(arena, .{ .name = name, .offset = t.offset });
        try where.append(arena, index);
        if (i + 6 < ts.len and ts[i + 5].is(".") and ts[i + 6].kind == .word) {
            try out.append(arena, .{ .name = name, .member = ts[i + 6].text, .offset = t.offset });
            try where.append(arena, index);
        }
        // const/var alias [: type] = @import(...); as used by layering checks.
        // The `;` comes first: it bounds the walk back to the declaration.
        if (i > 0 and ts[i - 1].is("=") and i + 5 < ts.len and ts[i + 5].is(";")) {
            var j = i - 1;
            while (j > 0 and !ts[j - 1].is(";") and !ts[j - 1].is("{") and !ts[j - 1].is("}")) : (j -= 1) {}
            if (j + 1 < i and (ts[j].is("const") or ts[j].is("var")) and ts[j + 1].kind == .word)
                try aliases.put(arena, ts[j + 1].text, name);
        }
    }
    // Short streams have at most a handful of declarations. Specialising
    // the temporary table keeps its mask constant in the word loop.
    if (out.items.len > 0) {
        if (ts.len <= 128) try classify(64, arena, ts, shape, &out, &where, aliases) else try classify(4096, arena, ts, shape, &out, &where, aliases);
    }
    return .{ .specs = try out.toOwnedSlice(arena), .unsupported = try unsupported.toOwnedSlice(arena) };
}

fn classify(comptime capacity: usize, arena: std.mem.Allocator, ts: []const l.Token, shape: liveness.Shape, out: *std.ArrayList(Spec), where: *std.ArrayList(u32), aliases: std.StringHashMapUnmanaged([]const u8)) std.mem.Allocator.Error!void {
    // No recovered reference borrows this table after classification.
    var slots: [capacity]u32 = undefined;
    // A short stream has at most 128 members and references. Its member
    // lists, name links and grouped traversal fit in this bounded workspace.
    // One allocator owns all of that temporary state until classification.
    var buffer: [if (capacity == 64) 24 * 1024 else 0]u8 = undefined;
    var scratch: std.heap.FixedBufferAllocator = .init(&buffer);
    const workspace = if (capacity == 64) scratch.allocator() else arena;
    var words = try liveness.Words.init(workspace, ts, shape, &slots);
    for (ts, 0..) |t, i| {
        if (t.kind == .string) try words.see(capacity, i);
        if (t.kind != .word) continue;
        try words.see(capacity, i);
        if (i + 2 >= ts.len or !dot(ts[i + 1]) or ts[i + 2].kind != .word) continue;
        if (i > 0 and dot(ts[i - 1])) continue;
        if (aliases.get(t.text)) |name| {
            try out.append(arena, .{ .name = name, .member = ts[i + 2].text, .offset = t.offset });
            try where.append(arena, @intCast(i));
        }
    }
    try words.classify(workspace, out.items, where.items);
}

// This hot check needs one byte, rather than generic slice equality.
inline fn dot(t: l.Token) bool {
    return (t.kind == .word or t.kind == .punctuation) and t.text.len == 1 and t.text[0] == '.';
}

const p = @import("../path.zig");
pub fn resolve(c: anytype, from: []const u8, spec: Spec) types.ResolveError![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const a = c.allocator;
    const dir = p.dir(from);
    const name = spec.name;
    // A `.zig` or `.zon` name is a file beside the importer; any other a module.
    if (std.mem.endsWith(u8, name, ".zig") or std.mem.endsWith(u8, name, ".zon")) {
        if (try c.candidate(dir, name, &.{""})) |v| try out.append(a, v);
    } else for (c.named_modules, c.named_from) |m, named_from| {
        if (std.mem.eql(u8, name, m.name) and named_from.matches(from)) {
            if (try c.candidate("", m.path, &.{""})) |v| try out.append(a, v);
            break;
        }
    }
    return out.toOwnedSlice(a);
}
pub const extensions = &[_][]const u8{".zig"};
