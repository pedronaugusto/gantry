//! Markdown and asset recovery have separate lexical rules from source code.
const std = @import("std");
const p = @import("path.zig");
const Spec = @import("types.zig").Spec;
const Context = @import("resolve.zig").Context;
pub const Names = std.StringHashMapUnmanaged(?[]const u8);
pub fn names(a: std.mem.Allocator, paths: []const []const u8) !Names {
    var map: Names = .empty;
    for (paths) |path| {
        const base = p.base(path);
        const key = if (std.mem.endsWith(u8, base, ".md")) base[0 .. base.len - 3] else base;
        const e = try map.getOrPut(a, key);
        e.value_ptr.* = if (e.found_existing) null else path;
    }
    return map;
}
pub fn links(a: std.mem.Allocator, text: []const u8) ![]const Spec {
    var out: std.ArrayList(Spec) = .empty;
    var i: usize = 0;
    var fence: u8 = 0;
    var fence_len: usize = 0;
    while (i < text.len) {
        if (i == 0 or text[i - 1] == '\n') {
            var start = i;
            while (start < text.len and start - i < 3 and text[start] == ' ') : (start += 1) {}
            var end = start;
            if (end < text.len and (text[end] == '`' or text[end] == '~')) {
                while (end < text.len and text[end] == text[start]) : (end += 1) {}
                if (end - start >= 3 and (fence == 0 or (text[start] == fence and end - start >= fence_len))) {
                    if (fence == 0) {
                        fence = text[start];
                        fence_len = end - start;
                    } else fence = 0;
                    i = std.mem.indexOfScalarPos(u8, text, end, '\n') orelse text.len;
                    if (i < text.len) i += 1;
                    continue;
                }
            }
        }
        if (fence != 0) {
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, text[i..], "<!--")) {
            i = if (std.mem.indexOfPos(u8, text, i + 4, "-->")) |end| end + 3 else text.len;
            continue;
        }
        if (text[i] == '\\') {
            i = @min(i + 2, text.len);
            continue;
        }
        if (text[i] == '`') {
            var end = i;
            while (end < text.len and text[end] == '`') : (end += 1) {}
            const marker = text[i..end];
            i = if (std.mem.indexOfPos(u8, text, end, marker)) |close| close + marker.len else end;
            continue;
        }
        if (std.mem.startsWith(u8, text[i..], "[[")) {
            const end = std.mem.indexOfPos(u8, text, i + 2, "]]") orelse {
                i += 2;
                continue;
            };
            const raw = text[i + 2 .. end];
            const name = std.mem.trim(u8, raw[0 .. std.mem.indexOfAny(u8, raw, "|#") orelse raw.len], " \t");
            if (name.len > 0) try out.append(a, .{ .name = name, .offset = i, .member = "wiki" });
            i = end + 2;
            continue;
        }
        if (std.mem.startsWith(u8, text[i..], "](")) {
            var start = i + 2;
            while (start < text.len and std.ascii.isWhitespace(text[start])) : (start += 1) {}
            const angle = start < text.len and text[start] == '<';
            if (angle) start += 1;
            var end = start;
            var depth: usize = 0;
            while (end < text.len) : (end += 1) {
                const c = text[end];
                if (c == '\\') {
                    end = @min(end + 1, text.len - 1);
                    continue;
                }
                if (angle) {
                    if (c == '>') break;
                } else {
                    if (c == '(') depth += 1;
                    if (c == ')') {
                        if (depth == 0) break;
                        depth -= 1;
                    }
                    if (std.ascii.isWhitespace(c) and depth == 0) break;
                }
            }
            const raw = text[start..end];
            const name = raw[0 .. std.mem.indexOfScalar(u8, raw, '#') orelse raw.len];
            if (name.len > 0 and std.mem.indexOfScalar(u8, name, ':') == null and name[0] != '/') try out.append(a, .{ .name = try unescape(a, name), .offset = i });
            i = end;
            continue;
        }
        i += 1;
    }
    return out.toOwnedSlice(a);
}
fn unescape(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < name.len) : (i += 1) {
        if (name[i] == '\\' and i + 1 < name.len) i += 1;
        try out.append(a, name[i]);
    }
    return out.toOwnedSlice(a);
}
pub fn linkTarget(ctx: Context, index: *const Names, from: []const u8, spec: Spec) !?[]const u8 {
    if (try ctx.candidate(p.dir(from), spec.name, &.{ "", ".md" })) |path| return path;
    if (spec.member != null) {
        if (try ctx.candidate("", spec.name, &.{ "", ".md" })) |path| return path;
        if (index.get(spec.name)) |entry| return entry;
    }
    return null;
}
pub fn assets(a: std.mem.Allocator, text: []const u8) ![]const Spec {
    var out: std.ArrayList(Spec) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (!pathByte(text[i])) {
            i += 1;
            continue;
        }
        const start = i;
        while (i < text.len and pathByte(text[i])) : (i += 1) {}
        const name = text[start..i];
        if (name.len >= 3) try out.append(a, .{ .name = name, .offset = start });
    }
    return out.toOwnedSlice(a);
}
fn pathByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c >= 128 or std.mem.indexOfScalar(u8, "./_-@", c) != null;
}
pub fn assetText(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    for ([_][]const u8{ ".md", ".txt", ".json", ".yaml", ".yml", ".toml", ".zon", ".html", ".css", ".xml", ".svg", ".csv" }) |e| if (std.mem.eql(u8, e, ext)) return true;
    return false;
}
