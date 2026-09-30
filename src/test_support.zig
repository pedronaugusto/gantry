const std = @import("std");
const g = @import("gantry.zig");
pub const Item = struct { path: []const u8, text: ?[]const u8 = "" };
pub const Fixture = struct {
    items: []const Item,
    pub fn read(self: Fixture, path: []const u8, a: std.mem.Allocator) !?[]const u8 {
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
pub fn edge(graph: *const g.Graph, from: []const u8, to: []const u8, kind: g.Kind, count: usize) !void {
    for (graph.edges) |e| if (std.mem.eql(u8, e.from, from) and std.mem.eql(u8, e.to, to) and e.kind == kind) {
        try std.testing.expectEqual(count, e.count);
        return;
    };
    std.debug.print("missing {s} -> {s}\n", .{ from, to });
    return error.TestExpectedEdge;
}
