//! One record of null reads across every phase of a scan.
const diagnostic_module = @import("diagnostic.zig");
const types_module = @import("../types.zig");
const std = @import("std");

pub fn Reader(comptime Context: type, comptime read: anytype) type {
    return struct {
        const Self = @This();
        context: Context,
        allocator: std.mem.Allocator,
        unread: std.StringHashMapUnmanaged(void) = .empty,
        progress: *diagnostic_module.Progress,

        pub fn deinit(self: *Self) void {
            self.unread.deinit(self.allocator);
            self.* = undefined;
        }
        pub fn readFile(scratch: std.mem.Allocator, self: *Self, path: []const u8) !?[]const u8 {
            self.progress.at(.read, path);
            const bytes = try read(scratch, self.context, path);
            if (bytes == null) try self.unread.put(self.allocator, path, {});
            return bytes;
        }
        /// Use graph-owned keys; config paths can belong to scan workspaces.
        pub fn unreadPaths(self: *const Self, a: std.mem.Allocator, files: *const std.StringHashMapUnmanaged(void)) ![]const []const u8 {
            const paths = try a.alloc([]const u8, self.unread.count());
            var keys = self.unread.keyIterator();
            var i: usize = 0;
            while (keys.next()) |key| : (i += 1) paths[i] = files.getKey(key.*).?;
            std.debug.assert(i == paths.len);
            std.mem.sort([]const u8, paths, {}, types_module.stringsLess);
            return paths;
        }
    };
}
