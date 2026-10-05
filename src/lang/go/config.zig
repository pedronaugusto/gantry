//! Local module routing, independent of dependency declaration extraction.
const path_module = @import("../../resolve/path.zig");
const std = @import("std");
const l = @import("../../lexer.zig");
pub const Requirement = struct { name: []const u8, version: []const u8 };
pub const Replacement = struct { name: []const u8, version: []const u8, root: ?[]const u8 };
pub const Module = struct { root: []const u8, name: []const u8, requires: []const Requirement = &.{}, replacements: []const Replacement = &.{} };
pub const Workspace = struct { root: []const u8, uses: []const []const u8, replacements: []const Replacement };
pub const Parsed = struct { name: ?[]const u8, requires: []const Requirement, replacements: []const Replacement, uses: []const []const u8 };
fn words(a: std.mem.Allocator, line: []const u8) ![]const []const u8 {
    const ts = try l.lex(.go, a, line);
    var out: std.ArrayList([]const u8) = .empty;
    var start: ?usize = null;
    var end: usize = 0;
    for (ts) |t| {
        if (t.kind == .newline) continue;
        if (t.kind == .string) {
            if (start) |s| {
                try out.append(a, line[s..end]);
                start = null;
            }
            try out.append(a, if (line[t.offset] == '`') t.text else try l.decode(a, t.text));
        } else {
            if (start != null and t.offset != end) {
                try out.append(a, line[start.?..end]);
                start = null;
            }
            if (start == null) start = t.offset;
            end = t.end;
        }
    }
    if (start) |s| try out.append(a, line[s..end]);
    return out.toOwnedSlice(a);
}
fn local(a: std.mem.Allocator, root: []const u8, name: []const u8) !?[]const u8 {
    if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..") and !std.mem.startsWith(u8, name, "./") and !std.mem.startsWith(u8, name, "../")) return null;
    return path_module.join(a, root, name, "") catch |err| switch (err) {
        error.InvalidPath => null,
        else => return err,
    };
}
pub fn parse(a: std.mem.Allocator, root: []const u8, text: []const u8) !Parsed {
    var name: ?[]const u8 = null;
    var requires: std.ArrayList(Requirement) = .empty;
    var replacements: std.ArrayList(Replacement) = .empty;
    var uses: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var block: []const u8 = "";
    while (lines.next()) |line| {
        var ws = try words(a, line);
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
        if (std.mem.eql(u8, directive, "use")) if (try local(a, root, ws[0])) |dir| {
            try uses.append(a, dir);
        };
        if (std.mem.eql(u8, directive, "require") and ws.len >= 2) try requires.append(a, .{ .name = ws[0], .version = ws[1] });
        if (std.mem.eql(u8, directive, "replace")) {
            var arrow: usize = 0;
            while (arrow < ws.len and !std.mem.eql(u8, ws[arrow], "=>")) : (arrow += 1) {}
            if ((arrow != 1 and arrow != 2) or arrow + 1 >= ws.len) return error.InvalidManifest;
            try replacements.append(a, .{ .name = ws[0], .version = if (arrow == 2) ws[1] else "", .root = try local(a, root, ws[arrow + 1]) });
        }
    }
    return .{ .name = name, .requires = try requires.toOwnedSlice(a), .replacements = try replacements.toOwnedSlice(a), .uses = try uses.toOwnedSlice(a) };
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
