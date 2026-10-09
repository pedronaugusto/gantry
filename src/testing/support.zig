const std = @import("std");
const shakedown = @import("shakedown");
const g = @import("../gantry.zig");
pub const Item = struct { path: []const u8, text: ?[]const u8 = "" };
pub const Fixture = struct {
    items: []const Item,
    pub fn read(self: Fixture, a: std.mem.Allocator, _: std.Io, path: []const u8) !?[]const u8 {
        for (self.items) |item| if (std.mem.eql(u8, item.path, path)) {
            return if (item.text) |text| try a.dupe(u8, text) else null;
        };
        return error.MissingFixture;
    }
    pub fn scan(self: Fixture, a: std.mem.Allocator, options: g.Options) !g.Graph {
        const paths = try a.alloc([]const u8, self.items.len);
        defer a.free(paths);
        for (self.items, paths) |item, *p| p.* = item.path;
        return g.scan(a, std.testing.io, paths, self, read, options);
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
        try std.testing.expectEqual(count, e.count.raw());
        return;
    };
    std.debug.print("missing {s} -> {s}\n", .{ from, to });
    return error.TestExpectedEdge;
}
/// `std.testing.checkAllAllocationFailures` over shakedown's `NoResize`,
/// whose every growth is an allocation, so each failing run repeats the
/// first run's count.
pub fn checkAllAllocationFailures(comptime test_fn: anytype, extra_args: anytype) !void {
    var backing: shakedown.alloc.NoResize = .init(std.testing.allocator);
    return std.testing.checkAllAllocationFailures(backing.allocator(), test_fn, extra_args);
}
