//! Markdown and asset recovery have separate lexical rules from source code.
const types_module = @import("types.zig");
const resolve_module = @import("resolve.zig");
const std = @import("std");
const p = @import("path.zig");
const Spec = types_module.Spec;
const Context = resolve_module.Context;
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
/// Every search for a closer is bounded or remembered, so the time is linear
/// in the text however many openers lack a closer.
pub fn links(a: std.mem.Allocator, text: []const u8) ![]const Spec {
    var out: std.ArrayList(Spec) = .empty;
    var spans = try CodeSpans.init(a, text);
    var i: usize = 0;
    var fence: u8 = 0;
    var fence_len: usize = 0;
    // A wiki link stays on its line; before this offset, no `]]` closes one.
    var wiki_unclosed: usize = 0;
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
                    i = std.mem.findScalarPos(u8, text, end, '\n') orelse text.len;
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
            i = if (std.mem.findPos(u8, text, i + 4, "-->")) |end| end + 3 else text.len;
            continue;
        }
        if (text[i] == '\\') {
            i = @min(i + 2, text.len);
            continue;
        }
        if (text[i] == '`') {
            var end = i;
            while (end < text.len and text[end] == '`') : (end += 1) {}
            i = spans.close(i, end - i) orelse end;
            continue;
        }
        if (std.mem.startsWith(u8, text[i..], "[[")) {
            const line = if (i < wiki_unclosed) wiki_unclosed else std.mem.findScalarPos(u8, text, i, '\n') orelse text.len;
            const end = (if (i < wiki_unclosed) null else std.mem.findPos(u8, text[0..line], i + 2, "]]")) orelse {
                wiki_unclosed = line;
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
            const name = raw[0 .. std.mem.findScalar(u8, raw, '#') orelse raw.len];
            if (name.len > 0 and std.mem.findScalar(u8, name, ':') == null and name[0] != '/') try out.append(a, .{ .name = try unescape(a, name), .offset = i });
            i = end;
            continue;
        }
        i += 1;
    }
    return out.toOwnedSlice(a);
}
/// Backtick runs by length, so a code span finds the next run of its own
/// length (CommonMark's closer) without searching the text again.
const CodeSpans = struct {
    /// Run starts by run length, ascending, with the next unread one.
    runs: std.AutoHashMapUnmanaged(usize, struct { starts: std.ArrayList(usize) = .empty, next: usize = 0 }) = .empty,

    fn init(a: std.mem.Allocator, text: []const u8) !CodeSpans {
        var spans: CodeSpans = .{};
        var i: usize = 0;
        while (std.mem.findScalarPos(u8, text, i, '`')) |start| {
            var end = start;
            while (end < text.len and text[end] == '`') : (end += 1) {}
            const entry = try spans.runs.getOrPut(a, end - start);
            if (!entry.found_existing) entry.value_ptr.* = .{};
            try entry.value_ptr.starts.append(a, start);
            i = end;
        }
        return spans;
    }
    /// The end of the run that closes the span opened at `start`, if any.
    /// Openers come in text order, so each length's cursor only moves on.
    fn close(spans: *CodeSpans, start: usize, len: usize) ?usize {
        const entry = spans.runs.getPtr(len) orelse return null;
        while (entry.next < entry.starts.items.len and entry.starts.items[entry.next] <= start) entry.next += 1;
        if (entry.next == entry.starts.items.len) return null;
        return entry.starts.items[entry.next] + len;
    }
};
/// A destination's backslash escapes, then its `%XX` bytes, as GitHub and
/// editors write a space (`my%20file.md`). Any other `%` stays as written.
fn unescape(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < name.len) : (i += 1) {
        if (name[i] == '\\' and i + 1 < name.len) {
            i += 1;
        } else if (name[i] == '%' and i + 2 < name.len and std.ascii.isHex(name[i + 1]) and std.ascii.isHex(name[i + 2])) {
            try out.append(a, hexDigit(name[i + 1]) << 4 | hexDigit(name[i + 2]));
            i += 2;
            continue;
        }
        try out.append(a, name[i]);
    }
    return out.toOwnedSlice(a);
}
fn hexDigit(c: u8) u8 {
    std.debug.assert(std.ascii.isHex(c));
    return if (c <= '9') c - '0' else (c | 0x20) - 'a' + 10;
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
    return std.ascii.isAlphanumeric(c) or c >= 128 or std.mem.findScalar(u8, "./_-@", c) != null;
}
pub fn assetText(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    for ([_][]const u8{ ".md", ".txt", ".json", ".yaml", ".yml", ".toml", ".zon", ".html", ".css", ".xml", ".svg", ".csv" }) |e| if (std.mem.eql(u8, e, ext)) return true;
    return false;
}
