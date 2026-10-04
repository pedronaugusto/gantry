//! One record of null reads across every phase of a scan.
const std = @import("std");

pub fn Reader(comptime Context: type, comptime read: anytype) type {
    return struct {
        const Self = @This();
        context: Context,
        allocator: std.mem.Allocator,
        unread: std.StringHashMapUnmanaged(void) = .empty,
        progress: *@import("diagnostic.zig").Progress,

        pub fn deinit(self: *Self) void {
            self.unread.deinit(self.allocator);
        }
        pub fn readFile(self: *Self, path: []const u8, scratch: std.mem.Allocator) !?[]const u8 {
            self.progress.at(.read, path);
            const bytes = try read(self.context, path, scratch);
            if (bytes == null) try self.unread.put(self.allocator, path, {});
            return bytes;
        }
        /// Use graph-owned keys; config paths can belong to scan workspaces.
        pub fn unreadPaths(self: *const Self, a: std.mem.Allocator, files: *const std.StringHashMapUnmanaged(void)) ![]const []const u8 {
            const paths = try a.alloc([]const u8, self.unread.count());
            var keys = self.unread.keyIterator();
            var i: usize = 0;
            while (keys.next()) |key| : (i += 1) paths[i] = files.getKey(key.*).?;
            std.mem.sort([]const u8, paths, {}, @import("../types.zig").stringsLess);
            return paths;
        }
    };
}
