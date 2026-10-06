const std = @import("std");
/// Always returns an owned slash-separated relative path. Refuses traversal
/// above the root, absolute paths, a drive (`C:` starting the path), a
/// backslash and NUL. A colon anywhere else is an ordinary byte.
pub fn normalize(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (!valid(raw)) return error.InvalidPath;
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(a);
    var it = std.mem.splitScalar(u8, raw, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (parts.pop() == null) return error.InvalidPath;
        } else try parts.append(a, part);
    }
    return std.mem.join(a, "/", parts.items);
}
/// Whether `normalize` takes these bytes, before traversal is resolved.
pub fn valid(raw: []const u8) bool {
    if (raw.len > 0 and (raw[0] == '/' or raw[0] == '\\')) return false;
    if (raw.len >= 2 and std.ascii.isAlphabetic(raw[0]) and raw[1] == ':') return false;
    return std.mem.findScalar(u8, raw, '\\') == null and std.mem.findScalar(u8, raw, 0) == null;
}
pub fn dir(p: []const u8) []const u8 {
    return if (std.mem.findScalarLast(u8, p, '/')) |i| p[0..i] else "";
}
pub fn base(p: []const u8) []const u8 {
    return if (std.mem.findScalarLast(u8, p, '/')) |i| p[i + 1 ..] else p;
}
pub fn within(root: []const u8, p: []const u8) bool {
    return root.len == 0 or std.mem.eql(u8, root, p) or (std.mem.startsWith(u8, p, root) and p.len > root.len and p[root.len] == '/');
}
pub fn directory(p: []const u8, depth: usize) []const u8 {
    const d = dir(p);
    if (depth == 0 or d.len == 0) return ".";
    var n: usize = 1;
    for (d, 0..) |c, i| if (c == '/') {
        if (n == depth) return d[0..i];
        n += 1;
    };
    return d;
}
