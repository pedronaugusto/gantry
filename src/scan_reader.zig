//! One record of null reads across every phase of a scan.
const std = @import("std");

pub fn Reader(comptime Context: type, comptime read: anytype) type {
    return struct {
        const Self = @This();
        context: Context,
        allocator: std.mem.Allocator,
        unread: std.StringHashMapUnmanaged(void) = .empty,

        pub fn deinit(self: *Self) void {
            self.unread.deinit(self.allocator);
        }
        pub fn readFile(self: *Self, path: []const u8, scratch: std.mem.Allocator) !?[]const u8 {
            const bytes = try read(self.context, path, scratch);
            if (bytes == null) try self.unread.put(self.allocator, path, {});
            return bytes;
        }
        pub fn unreadPaths(self: *const Self, a: std.mem.Allocator) ![]const []const u8 {
            const paths = try a.alloc([]const u8, self.unread.count());
            var keys = self.unread.keyIterator();
            var i: usize = 0;
            while (keys.next()) |key| : (i += 1) paths[i] = key.*;
            std.mem.sort([]const u8, paths, {}, @import("types.zig").stringsLess);
            return paths;
        }
    };
}
