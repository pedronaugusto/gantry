//! The one reader of `go.mod` and `go.work`: local module routing, and the
//! requirements `manifests` declares.
const path_module = @import("../../resolve/path.zig");
const std = @import("std");
const l = @import("../../lexer.zig");
/// `indirect` marks a module only other modules import: a `// indirect`
/// comment, the word alone or before a `;`, as Go reads it.
pub const Requirement = struct { name: []const u8, version: []const u8, indirect: bool = false };
pub const Replacement = struct { name: []const u8, version: []const u8, root: ?[]const u8 };
pub const Module = struct { root: []const u8, name: []const u8, requires: []const Requirement = &.{}, replacements: []const Replacement = &.{} };
pub const Workspace = struct { root: []const u8, uses: []const []const u8, replacements: []const Replacement };
pub const Parsed = struct { name: ?[]const u8, requires: []const Requirement, replacements: []const Replacement, uses: []const []const u8 };
/// A line's words, and the text of a `//` comment after them.
const Line = struct { words: []const []const u8, comment: []const u8 };
fn words(arena: std.mem.Allocator, line: []const u8) !Line {
    const ts = try l.lex(.go, arena, line);
    var out: std.ArrayList([]const u8) = .empty;
    var start: ?usize = null;
    var end: usize = 0;
    var last: usize = 0;
    for (ts) |t| {
        if (t.kind == .newline) continue;
        last = t.end;
        if (t.kind == .string) {
            if (start) |s| {
                try out.append(arena, line[s..end]);
                start = null;
            }
            try out.append(arena, if (line[t.offset] == '`') t.text else try l.decode(arena, t.text));
        } else {
            if (start != null and t.offset != end) {
                try out.append(arena, line[start.?..end]);
                start = null;
            }
            if (start == null) start = t.offset;
            end = t.end;
        }
    }
    if (start) |s| try out.append(arena, line[s..end]);
    const rest = std.mem.trim(u8, line[last..], " \t\r");
    const comment = if (std.mem.startsWith(u8, rest, "//")) std.mem.trim(u8, rest[2..], " \t\r") else "";
    return .{ .words = try out.toOwnedSlice(arena), .comment = comment };
}
fn local(arena: std.mem.Allocator, root: []const u8, name: []const u8) !?[]const u8 {
    if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..") and !std.mem.startsWith(u8, name, "./") and !std.mem.startsWith(u8, name, "../")) return null;
    return path_module.join(arena, root, name, "") catch |err| switch (err) {
        error.InvalidPath => null,
        else => |e| return e,
    };
}
pub fn parse(arena: std.mem.Allocator, root: []const u8, text: []const u8) error{ InvalidEscape, InvalidManifest, OutOfMemory }!Parsed {
    var name: ?[]const u8 = null;
    var requires: std.ArrayList(Requirement) = .empty;
    var replacements: std.ArrayList(Replacement) = .empty;
    var uses: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var block: []const u8 = "";
    while (lines.next()) |text_line| {
        const line = try words(arena, text_line);
        var ws = line.words;
        if (ws.len == 0) continue;
        if (std.mem.eql(u8, ws[0], ")")) {
            block = "";
            continue;
        }
        var directive = block;
        if (block.len == 0) {
            directive = ws[0];
            ws = ws[1..];
        }
        if (ws.len == 0) continue;
        if (std.mem.eql(u8, ws[0], "(")) {
            block = directive;
            continue;
        }
        if (std.mem.eql(u8, directive, "module")) name = ws[0];
        if (std.mem.eql(u8, directive, "use")) if (try local(arena, root, ws[0])) |dir| {
            try uses.append(arena, dir);
        };
        if (std.mem.eql(u8, directive, "require")) {
            if (ws.len < 2) return error.InvalidManifest;
            const indirect = std.mem.eql(u8, line.comment, "indirect") or std.mem.startsWith(u8, line.comment, "indirect;");
            try requires.append(arena, .{ .name = ws[0], .version = ws[1], .indirect = indirect });
        }
        if (std.mem.eql(u8, directive, "replace")) {
            var arrow: usize = 0;
            while (arrow < ws.len and !std.mem.eql(u8, ws[arrow], "=>")) : (arrow += 1) {}
            if ((arrow != 1 and arrow != 2) or arrow + 1 >= ws.len) return error.InvalidManifest;
            try replacements.append(arena, .{ .name = ws[0], .version = if (arrow == 2) ws[1] else "", .root = try local(arena, root, ws[arrow + 1]) });
        }
    }
    if (block.len > 0) return error.InvalidManifest;
    return .{ .name = name, .requires = try requires.toOwnedSlice(arena), .replacements = try replacements.toOwnedSlice(arena), .uses = try uses.toOwnedSlice(arena) };
}
pub fn used(work: Workspace, root: []const u8) bool {
    for (work.uses) |use| if (std.mem.eql(u8, use, root)) return true;
    return false;
}
pub fn replacement(items: []const Replacement, name: []const u8, version: []const u8) ?Replacement {
    var best: ?Replacement = null;
    for (items) |r| if (std.mem.eql(u8, r.name, name) and (r.version.len == 0 or std.mem.eql(u8, r.version, version))) {
        if (best == null or r.version.len > 0) best = r;
    };
    return best;
}
