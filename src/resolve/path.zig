//! Join repository-relative names without turning absolute names into relative ones.
const std = @import("std");
const path = @import("../path.zig");

pub fn join(a: std.mem.Allocator, root: []const u8, name: []const u8, suffix: []const u8) ![]const u8 {
    if (name.len > 0 and name[0] == '/') return error.InvalidPath;
    const raw = try a.print("{s}{s}{s}{s}", .{ root, if (root.len == 0) "" else "/", name, suffix });
    defer a.free(raw);
    return path.normalize(a, raw);
}
