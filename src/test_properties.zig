const std = @import("std");
const g = @import("gantry.zig");
const a = std.testing.allocator;
test "generated graphs agree with transitive reachability and longest condensation paths" {
    const n = 10;
    const paths = &[_][]const u8{ "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" };
    var random: std.Random.DefaultPrng = .init(0x67616e747279);
    for (0..128) |_| {
        var edges: std.ArrayList(g.Edge) = .empty;
        defer edges.deinit(a);
        var reach: [n][n]bool = @splat(@splat(false));
        for (0..n) |v| for (0..n) |w| if (random.random().uintLessThan(u8, 10) < 2) {
            reach[v][w] = true;
            try edges.append(a, .{ .from = paths[v], .to = paths[w] });
        };
        const direct = reach;
        for (0..n) |k| for (0..n) |v| for (0..n) |w| {
            reach[v][w] = reach[v][w] or (reach[v][k] and reach[k][w]);
        };
        var graph = try g.Graph.fromEdges(a, paths, edges.items);
        defer graph.deinit();
        var analysis = try graph.analyze(a);
        defer analysis.deinit();
        var component: [n]usize = undefined;
        for (analysis.components, 0..) |group, id| for (group) |path| {
            component[path[0] - '0'] = id;
        };
        for (0..n) |v| for (0..n) |w| {
            try std.testing.expectEqual(v == w or (reach[v][w] and reach[w][v]), component[v] == component[w]);
        };
        // An independent bounded relaxation over the condensation is an
        // oracle for longest depths, without using the library's traversal.
        var depth: [n]usize = @splat(0);
        for (0..n) |_| for (0..n) |v| for (0..n) |w| if (direct[v][w] and component[v] != component[w]) {
            depth[component[w]] = @max(depth[component[w]], depth[component[v]] + 1);
        };
        for (analysis.layers, 0..) |layer, v| try std.testing.expectEqual(depth[component[v]], layer.depth);
        var cyclic: [n]bool = @splat(false);
        for (analysis.cycles) |cycle| {
            for (cycle.members) |path| cyclic[path[0] - '0'] = true;
            for (cycle.path[0 .. cycle.path.len - 1], cycle.path[1..]) |from, to| try std.testing.expect(direct[from[0] - '0'][to[0] - '0']);
        }
        for (0..n) |v| try std.testing.expectEqual(reach[v][v], cyclic[v]);
    }
}
