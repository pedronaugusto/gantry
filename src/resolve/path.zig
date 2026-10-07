//! Join repository-relative names without turning absolute names into relative ones.
const std = @import("std");
const path = @import("../path.zig");

pub fn join(gpa: std.mem.Allocator, root: []const u8, name: []const u8, suffix: []const u8) error{ InvalidPath, OutOfMemory }![]const u8 {
    if (name.len > 0 and name[0] == '/') return error.InvalidPath;
    const raw = try gpa.print("{s}{s}{s}{s}", .{ root, if (root.len == 0) "" else "/", name, suffix });
    defer gpa.free(raw);
    return path.normalize(gpa, raw);
}
