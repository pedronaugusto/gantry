//! One record of null reads across every phase of a scan.
const diagnostic_module = @import("diagnostic.zig");
const types_module = @import("../types.zig");
const std = @import("std");

pub fn Reader(comptime Context: type, comptime read: anytype) type {
    comptime check(Context, read);
    return struct {
        const Self = @This();
        context: Context,
        /// Passed to every read; this reader lives for one scan call.
        io: std.Io,
        allocator: std.mem.Allocator,
        unread: std.StringHashMapUnmanaged(void) = .empty,
        progress: *diagnostic_module.Progress,

        pub fn deinit(self: *Self) void {
            self.unread.deinit(self.allocator);
            self.* = undefined;
        }
        pub fn readFile(self: *Self, scratch: std.mem.Allocator, path: []const u8) (diagnostic_module.ReadError(read) || error{OutOfMemory})!?[]const u8 {
            self.progress.at(.read, path);
            const bytes = try read(self.context, scratch, self.io, path);
            if (bytes == null) try self.unread.put(self.allocator, path, {});
            return bytes;
        }
        /// Use graph-owned keys; config paths can belong to scan workspaces.
        pub fn unreadPaths(self: *const Self, arena: std.mem.Allocator, files: *const std.StringHashMapUnmanaged(void)) std.mem.Allocator.Error![]const []const u8 {
            const paths = try arena.alloc([]const u8, self.unread.count());
            var keys = self.unread.keyIterator();
            var i: usize = 0;
            while (keys.next()) |key| : (i += 1) paths[i] = files.getKey(key.*).?;
            std.debug.assert(i == paths.len);
            std.mem.sort([]const u8, paths, {}, types_module.stringsLess);
            return paths;
        }
    };
}

/// A reader is `fn (context, scratch: std.mem.Allocator, io: std.Io, path:
/// []const u8) E!?[]const u8`, the value it is called on first, as every
/// method takes it; anything else fails here by that name.
fn check(comptime Context: type, comptime read: anytype) void {
    const expected = "gantry.scan: read must be fn (context: " ++ @typeName(Context) ++ ", scratch: std.mem.Allocator, io: std.Io, path: []const u8) E!?[]const u8, not ";
    const info = switch (@typeInfo(@TypeOf(read))) {
        .@"fn" => |f| f,
        else => @compileError(expected ++ @typeName(@TypeOf(read))),
    };
    const params = info.param_types;
    const shaped = params.len == 4 and params[1] == std.mem.Allocator and params[2] == std.Io and params[3] == []const u8;
    if (!shaped) @compileError(expected ++ @typeName(@TypeOf(read)));
}
