//! `build.gradle` and `build.gradle.kts` dependencies, read lexically and
//! never evaluated.
const std = @import("std");
const l = @import("../lexer.zig");
const t = @import("../types.zig");
const Token = l.Token;

/// Each statement of a `dependencies { }` block, wherever the block sits
/// (`buildscript`, `subprojects`): a configuration with literal notations.
/// A notation is a `"group:name:version"` string, a map of literal
/// `group`, `name` and `version`, `project(":path")`, or `platform(…)` and
/// `enforcedPlatform(…)` around a string. Its group is the configuration.
/// Anything computed (a variable, an interpolated string, a version catalog
/// `libs.x`, `kotlin("x")`, `files(…)`, control flow) is unsupported and
/// declares nothing. `constraints { }` holds no declarations.
pub fn parse(arena: std.mem.Allocator, path: []const u8, text: []const u8, out: *std.ArrayList(t.Dependency), unsupported: *std.ArrayList(t.UnsupportedReference)) error{ InvalidManifest, InvalidEscape, OutOfMemory }!void {
    const ts = if (std.mem.endsWith(u8, path, ".kts")) try l.lex(.kotlin, arena, text) else try l.lex(.groovy, arena, text);
    var blocks: std.ArrayList(bool) = .empty;
    var i: usize = 0;
    while (i < ts.len) {
        const token = ts[i];
        if (token.is("}")) {
            _ = blocks.pop();
            i += 1;
            continue;
        }
        if (token.is("{")) {
            const opens = i > 0 and ts[i - 1].is("dependencies") and (i < 2 or !ts[i - 2].is("."));
            try blocks.append(arena, opens);
            i += 1;
            continue;
        }
        const inside = blocks.items.len > 0 and blocks.items[blocks.items.len - 1];
        if (!inside or token.kind == .newline or token.is(";")) {
            i += 1;
            continue;
        }
        const before = out.items.len;
        var reader: Reader = .{ .arena = arena, .path = path, .ts = ts, .i = i, .out = out };
        const literal = reader.statement() catch |err| switch (err) {
            error.Computed => false,
            else => |e| return e,
        };
        if (!literal) {
            out.shrinkRetainingCapacity(before);
            try unsupported.append(arena, .{ .offset = token.offset, .expression = .gradle_dependency });
            // A stray closing bracket is its own statement; always move on.
            reader.i = @max(skip(ts, i), i + 1);
        }
        i = reader.i;
    }
}
/// The bracket closing the one opened just before `from`, or the end.
fn closing(ts: []const Token, from: usize) usize {
    var depth: usize = 0;
    var i = from;
    while (i < ts.len) : (i += 1) {
        if (ts[i].is("(") or ts[i].is("[") or ts[i].is("{")) depth += 1;
        if (ts[i].is(")") or ts[i].is("]") or ts[i].is("}")) {
            if (depth == 0) return i;
            depth -= 1;
        }
    }
    return i;
}
/// The end of a statement: its newline or `;` outside brackets, or the
/// `}` that closes its block.
fn skip(ts: []const Token, from: usize) usize {
    var depth: usize = 0;
    var i = from;
    while (i < ts.len) : (i += 1) {
        if (ts[i].is("(") or ts[i].is("[") or ts[i].is("{")) depth += 1;
        if (ts[i].is(")") or ts[i].is("]") or ts[i].is("}")) {
            if (depth == 0) return i;
            depth -= 1;
        }
        if (depth == 0 and (ts[i].kind == .newline or ts[i].is(";"))) return i;
    }
    return i;
}
const Reader = struct {
    arena: std.mem.Allocator,
    path: []const u8,
    ts: []const Token,
    i: usize,
    out: *std.ArrayList(t.Dependency),

    fn peek(r: *Reader, s: []const u8) bool {
        return r.i < r.ts.len and r.ts[r.i].is(s);
    }
    fn expect(r: *Reader, s: []const u8) !void {
        if (!r.peek(s)) return error.Computed;
        r.i += 1;
    }
    fn newlines(r: *Reader) void {
        while (r.i < r.ts.len and r.ts[r.i].kind == .newline) : (r.i += 1) {}
    }
    /// True when the statement declared only literal notations.
    fn statement(r: *Reader) !bool {
        const first = r.ts[r.i];
        if (first.kind == .word and r.i + 1 < r.ts.len and r.ts[r.i + 1].is("{") and declaresNothing(first.text)) {
            r.i = @min(closing(r.ts, r.i + 2) + 1, r.ts.len);
            return true;
        }
        var configuration: []const u8 = undefined;
        if (first.is("add") and r.i + 3 < r.ts.len and r.ts[r.i + 1].is("(") and r.ts[r.i + 2].kind == .string and r.ts[r.i + 3].is(",")) {
            // `add("configuration", notation)`
            configuration = r.ts[r.i + 2].text;
            r.i += 4;
            r.newlines();
            try r.notation(configuration);
            try r.expect(")");
        } else {
            if (first.kind != .word and first.kind != .string) return false;
            configuration = first.text;
            r.i += 1;
            const parens = r.peek("(");
            if (parens) r.i += 1;
            try r.arguments(configuration, parens);
            if (parens) try r.expect(")");
        }
        // A closure configures the declaration: `{ exclude … }`.
        if (r.peek("{")) r.i = @min(closing(r.ts, r.i + 1) + 1, r.ts.len);
        return r.i == r.ts.len or r.ts[r.i].kind == .newline or r.peek(";") or r.peek("}");
    }
    fn arguments(r: *Reader, configuration: []const u8, parens: bool) !void {
        if (parens) r.newlines();
        // A map: `group: 'g', name: 'a'` or `group = "g", name = "a"`.
        if (r.i + 1 < r.ts.len and r.ts[r.i].kind == .word and (r.ts[r.i + 1].is(":") or r.ts[r.i + 1].is("="))) return r.map(configuration);
        while (true) {
            try r.notation(configuration);
            if (!r.peek(",")) return;
            r.i += 1;
            r.newlines();
        }
    }
    fn notation(r: *Reader, configuration: []const u8) !void {
        if (r.i >= r.ts.len) return error.Computed;
        const token = r.ts[r.i];
        if (token.kind == .string) {
            r.i += 1;
            return r.coordinates(configuration, token.text);
        }
        const project = token.is("project");
        if (!project and !token.is("platform") and !token.is("enforcedPlatform")) return error.Computed;
        r.i += 1;
        try r.expect("(");
        r.newlines();
        if (project and r.i + 2 < r.ts.len and r.ts[r.i].is("path") and (r.ts[r.i + 1].is(":") or r.ts[r.i + 1].is("="))) r.i += 2;
        if (r.i >= r.ts.len or r.ts[r.i].kind != .string) return error.Computed;
        const value = r.ts[r.i].text;
        r.i += 1;
        r.newlines();
        try r.expect(")");
        if (!project) return r.coordinates(configuration, value);
        // Another project of the same build.
        try r.out.append(r.arena, .{ .manifest = r.path, .name = value, .group = configuration, .origin = .workspace });
    }
    fn map(r: *Reader, configuration: []const u8) !void {
        var group: []const u8 = "";
        var name: []const u8 = "";
        var version: []const u8 = "";
        while (true) {
            if (r.i + 2 >= r.ts.len or r.ts[r.i].kind != .word or !(r.ts[r.i + 1].is(":") or r.ts[r.i + 1].is("="))) return error.Computed;
            const literal = r.ts[r.i + 2].kind == .string or r.ts[r.i + 2].is("true") or r.ts[r.i + 2].is("false");
            if (!literal) return error.Computed;
            const key = r.ts[r.i].text;
            const value = r.ts[r.i + 2].text;
            if (std.mem.eql(u8, key, "group")) group = value else if (std.mem.eql(u8, key, "name")) name = value else if (std.mem.eql(u8, key, "version")) version = value;
            r.i += 3;
            if (!r.peek(",")) break;
            r.i += 1;
            r.newlines();
        }
        if (group.len == 0 or name.len == 0) return error.Computed;
        try r.out.append(r.arena, .{ .manifest = r.path, .name = try r.arena.print("{s}:{s}", .{ group, name }), .requirement = version, .group = configuration });
    }
    /// `group:name`, then the version and any classifier or `@extension`.
    fn coordinates(r: *Reader, configuration: []const u8, value: []const u8) !void {
        const first = std.mem.findScalar(u8, value, ':') orelse return error.Computed;
        const second = std.mem.findScalarPos(u8, value, first + 1, ':') orelse value.len;
        if (first == 0 or second == first + 1) return error.Computed;
        try r.out.append(r.arena, .{
            .manifest = r.path,
            .name = value[0..second],
            .requirement = if (second < value.len) value[second + 1 ..] else "",
            .group = configuration,
        });
    }
};
/// Blocks inside `dependencies` that configure resolution, not declare.
fn declaresNothing(word: []const u8) bool {
    for ([_][]const u8{ "constraints", "components", "modules", "attributesSchema", "artifactTypes", "registerTransform" }) |block| if (std.mem.eql(u8, word, block)) return true;
    return false;
}
