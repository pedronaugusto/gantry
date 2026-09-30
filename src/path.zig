const std = @import("std");
/// Always returns an owned slash-separated relative path. Refuses traversal
/// above the root, absolute paths and platform-specific drive spellings.
pub fn normalize(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (raw.len > 0 and (raw[0] == '/' or raw[0] == '\\')) return error.InvalidPath;
    if (std.mem.indexOfScalar(u8, raw, ':') != null or std.mem.indexOfScalar(u8, raw, '\\') != null or std.mem.indexOfScalar(u8, raw, 0) != null) return error.InvalidPath;
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
pub fn dir(p: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, p, '/')) |i| p[0..i] else "";
}
pub fn base(p: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, p, '/')) |i| p[i + 1 ..] else p;
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
