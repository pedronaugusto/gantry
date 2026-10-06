const std = @import("std");
const g = @import("../gantry.zig");
pub const Item = struct { path: []const u8, text: ?[]const u8 = "" };
pub const Fixture = struct {
    items: []const Item,
    pub fn read(a: std.mem.Allocator, self: Fixture, path: []const u8) !?[]const u8 {
        for (self.items) |item| if (std.mem.eql(u8, item.path, path)) {
            return if (item.text) |text| try a.dupe(u8, text) else null;
        };
        return error.MissingFixture;
    }
    pub fn scan(self: Fixture, a: std.mem.Allocator, options: g.Options) !g.Graph {
        const paths = try a.alloc([]const u8, self.items.len);
        defer a.free(paths);
        for (self.items, paths) |item, *p| p.* = item.path;
        return g.scan(a, paths, self, read, options);
    }
};
/// `graph` has one invalid file, `path`, for `cause`.
pub fn invalid(graph: *const g.Graph, path: []const u8, cause: g.FileError) !void {
    try std.testing.expectEqual(1, graph.invalid().len);
    try std.testing.expectEqualStrings(path, graph.invalid()[0].path);
    try std.testing.expectEqual(cause, graph.invalid()[0].cause);
}
pub fn edge(graph: *const g.Graph, from: []const u8, to: []const u8, kind: g.Kind, count: usize) !void {
    for (graph.edges()) |e| if (std.mem.eql(u8, e.from, from) and std.mem.eql(u8, e.to, to) and e.kind == kind) {
        try std.testing.expectEqual(count, e.count);
        return;
    };
    std.debug.print("missing {s} -> {s}\n", .{ from, to });
    return error.TestExpectedEdge;
}
/// The most bytes held at once through `allocator()`.
pub const Peak = struct {
    child: std.mem.Allocator,
    live: usize = 0,
    peak: usize = 0,
    pub fn allocator(self: *Peak) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn grow(self: *Peak, old: usize, new: usize) void {
        self.live = self.live - old + new;
        self.peak = @max(self.peak, self.live);
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *Peak = @ptrCast(@alignCast(ctx)); // safe: allocator() stores the original aligned Peak pointer as its callback context.
        const result = self.child.rawAlloc(len, alignment, ret) orelse return null;
        self.grow(0, len);
        return result;
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) bool {
        const self: *Peak = @ptrCast(@alignCast(ctx)); // safe: allocator() stores the original aligned Peak pointer as its callback context.
        if (!self.child.rawResize(memory, alignment, len, ret)) return false;
        self.grow(memory.len, len);
        return true;
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) ?[*]u8 {
        const self: *Peak = @ptrCast(@alignCast(ctx)); // safe: allocator() stores the original aligned Peak pointer as its callback context.
        const result = self.child.rawRemap(memory, alignment, len, ret) orelse return null;
        self.grow(memory.len, len);
        return result;
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *Peak = @ptrCast(@alignCast(ctx)); // safe: allocator() stores the original aligned Peak pointer as its callback context.
        self.child.rawFree(memory, alignment, ret);
        self.grow(memory.len, 0);
    }
};
