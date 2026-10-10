//! Zig, read through glint's token tier: std's own tokenizer, the imports
//! and test contexts of `@import`, and which of them only tests reach. It is
//! a module apart, importing `gantry` while the core imports nothing of it,
//! so that a project that never analyses Zig never fetches glint. List `frontend` in `Options.frontends` to scan Zig files.
const std = @import("std");
const seam = @import("gantry").frontend;
const tokens = @import("glint").token;

/// What a scan lists in `Options.frontends` to read `.zig` files.
pub const frontend: seam.Frontend = .{ .language = .zig, .recover = recover };

/// A file's `@import`s with their member spellings, test kinds and liveness,
/// and the operands of any `@import` that is not a string literal.
fn recover(arena: std.mem.Allocator, source: []const u8, seen: ?seam.Observer) seam.RecoverError!seam.Recovery {
    var bridge: Bridge = .{ .source = source };
    const facts = if (seen) |observer| watched: {
        bridge.seen = observer;
        break :watched try tokens.scan(arena, source, .{
            .context = &bridge,
            .punctuation = observer.punctuation,
            .boundary = Bridge.boundary,
            .token = Bridge.token,
        });
    } else try tokens.scan(arena, source, null);
    const specs = try arena.alloc(seam.Spec, facts.imports.len);
    for (facts.imports, specs) |import, *spec| spec.* = .{
        .name = import.name,
        .member = import.member,
        .offset = import.offset,
        .kind = switch (import.kind) {
            .import => .import,
            .@"test" => .@"test",
        },
        .dead = import.dead,
    };
    const unsupported = try arena.alloc(seam.UnsupportedReference, facts.unsupported.len);
    for (facts.unsupported, unsupported) |record, *out| out.* = .{ .offset = record.offset, .expression = .zig_import };
    return .{ .specs = specs, .unsupported = unsupported };
}

/// Hands the units glint reads to a token rule's observer in the shape every
/// frontend gives: a word is a name, keyword or number, an `@"name"` is one
/// word, and punctuation is a byte unless it is part of a longer operator.
const Bridge = struct {
    source: []const u8,
    /// Set before glint reads, whenever glint is given the bridge at all.
    seen: ?seam.Observer = null,
    /// The last two units handed over: an observer reads no further back.
    window: [2]seam.Lexeme = @splat(.{ .kind = .word, .text = "", .offset = 0, .end = 0 }),
    delivered: usize = 0,
    /// The operator whose last byte has not yet arrived.
    operator: ?seam.Lexeme = null,

    fn token(context: *anyopaque, current: tokens.Token) error{OutOfMemory}!void {
        const b: *Bridge = @ptrCast(@alignCast(context)); // safe: `recover` passes its own bridge as the context.
        const unit: seam.Lexeme = .{
            .kind = switch (current.kind()) {
                .word, .keyword, .literal => .word,
                .string => .string,
                .punctuation => .punctuation,
            },
            .text = current.text,
            .offset = current.offset,
            .end = current.end(),
        };
        if (unit.kind != .punctuation) return b.deliver(unit);
        if (b.operator) |operator| {
            if (unit.end != operator.end) return;
            b.operator = null;
            return b.deliver(operator);
        }
        const length = zigOperatorLength(b.source[unit.offset..]);
        if (length == 1) return b.deliver(unit);
        b.operator = .{ .kind = .punctuation, .text = b.source[unit.offset..][0..length], .offset = unit.offset, .end = unit.offset + length };
    }

    fn deliver(b: *Bridge, unit: seam.Lexeme) error{OutOfMemory}!void {
        b.window[0] = b.window[1];
        b.window[1] = unit;
        b.delivered += 1;
        const observer = b.seen.?;
        try observer.token(observer.context, if (b.delivered == 1) b.window[1..] else &b.window);
    }

    fn boundary(context: *anyopaque) void {
        const b: *Bridge = @ptrCast(@alignCast(context)); // safe: `recover` passes its own bridge as the context.
        b.operator = null;
        const observer = b.seen.?;
        if (observer.boundary) |call| call(observer.context);
    }
};

/// Length of Zig's longest punctuation token at this byte. glint keeps
/// punctuation bytes separate; sequence rules must not cut an operator in
/// half. The compiler's token vocabulary owns which runs are operators.
fn zigOperatorLength(text: []const u8) usize {
    if (text.len < 2 or std.ascii.isWhitespace(text[1]) or std.ascii.isAlphanumeric(text[1])) return @min(text.len, 1);
    var length: usize = 1;
    inline for (comptime std.meta.tags(std.zig.Token.Tag)) |tag| {
        if (comptime tag.lexeme()) |spelling| {
            if (comptime spelling.len > 1 and !std.ascii.isAlphabetic(spelling[0])) {
                if (spelling.len > length and std.mem.startsWith(u8, text, spelling)) length = spelling.len;
            }
        }
    }
    return length;
}
