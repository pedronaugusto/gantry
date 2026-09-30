const std = @import("std");
const g = @import("gantry.zig");
const f = @import("test_support.zig");
const a = std.testing.allocator;
const eq = std.testing.expectEqual;
const expect = std.testing.expect;
test "longest path depths include shortcuts disconnected nodes and collapsed SCCs" {
    var graph = try g.Graph.fromEdges(a, &.{ "a", "b", "c", "d", "e", "isolated" }, &.{
        .{ .from = "a", .to = "b" }, .{ .from = "b", .to = "c" }, .{ .from = "c", .to = "d" }, .{ .from = "a", .to = "d" }, .{ .from = "d", .to = "e" }, .{ .from = "e", .to = "d" },
    });
    defer graph.deinit();
    var analysis = try graph.analyze(a);
    defer analysis.deinit();
    const depths = [_]usize{ 0, 1, 2, 3, 3, 0 };
    for (analysis.layers, depths) |layer, depth| try eq(depth, layer.depth);
    try eq(1, analysis.cycles.len);
    try eq(2, analysis.cycles[0].members.len);
    try std.testing.expectEqualStrings("d", analysis.cycles[0].path[0]);
    try std.testing.expectEqualStrings("d", analysis.cycles[0].path[2]);
}
test "SCCs find cycles longer than mutual pairs and self imports" {
    var graph = try g.Graph.fromEdges(a, &.{ "a", "b", "c", "d", "e" }, &.{ .{ .from = "a", .to = "b" }, .{ .from = "b", .to = "c" }, .{ .from = "c", .to = "a" }, .{ .from = "d", .to = "d" } });
    defer graph.deinit();
    var analysis = try graph.analyze(a);
    defer analysis.deinit();
    try eq(2, analysis.cycles.len);
    try eq(3, analysis.cycles[0].members.len);
    try eq(4, analysis.cycles[0].path.len);
    try eq(2, analysis.cycles[1].path.len);
    for (analysis.cycles) |cycle| {
        for (cycle.path[0 .. cycle.path.len - 1], cycle.path[1..]) |from, to| try f.edge(&graph, from, to, .import, 1);
    }
}
test "cycle witnesses use edges rather than sorting the members into a fake loop" {
    var graph = try g.Graph.fromEdges(a, &.{ "a", "b", "c", "d" }, &.{ .{ .from = "a", .to = "c" }, .{ .from = "c", .to = "b" }, .{ .from = "b", .to = "d" }, .{ .from = "d", .to = "a" } });
    defer graph.deinit();
    var analysis = try graph.analyze(a);
    defer analysis.deinit();
    const want = &[_][]const u8{ "a", "c", "b", "d", "a" };
    for (want, analysis.cycles[0].path) |w, path| try std.testing.expectEqualStrings(w, path);
}
test "deep graphs use heap stacks in SCC and layer analysis" {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    const n = 20_000;
    const paths = try alloc.alloc([]const u8, n);
    for (paths, 0..) |*path, i| path.* = try std.fmt.allocPrint(alloc, "{d:0>5}", .{i});
    const edges = try alloc.alloc(g.Edge, n - 1);
    for (edges, 0..) |*edge, i| edge.* = .{ .from = paths[i], .to = paths[i + 1] };
    var graph = try g.Graph.fromEdges(a, paths, edges);
    defer graph.deinit();
    var analysis = try graph.analyze(a);
    defer analysis.deinit();
    try eq(n - 1, analysis.layers[n - 1].depth);
    try eq(0, analysis.cycles.len);
}
test "every node in a rootless cycle shares depth zero" {
    var graph = try g.Graph.fromEdges(a, &.{ "a", "b" }, &.{ .{ .from = "a", .to = "b" }, .{ .from = "b", .to = "a" } });
    defer graph.deinit();
    var analysis = try graph.analyze(a);
    defer analysis.deinit();
    for (analysis.layers) |layer| try eq(0, layer.depth);
}
test "file edge occurrence counts keep kinds separate and reject overflow" {
    var graph = try g.Graph.fromEdges(a, &.{ "a", "b" }, &.{ .{ .from = "a", .to = "b" }, .{ .from = "a", .to = "b", .count = 2 }, .{ .from = "a", .to = "b", .kind = .link }, .{ .from = "a", .to = "b", .kind = .asset } });
    defer graph.deinit();
    try eq(3, graph.edges.len);
    try f.edge(&graph, "a", "b", .import, 3);
    try std.testing.expectError(error.InvalidCount, g.Graph.fromEdges(a, &.{ "a", "b" }, &.{.{ .from = "a", .to = "b", .count = 0 }}));
    try std.testing.expectError(error.UnknownPath, g.Graph.fromEdges(a, &.{"a"}, &.{.{ .from = "a", .to = "missing" }}));
    try std.testing.expectError(error.CountOverflow, g.Graph.fromEdges(a, &.{ "a", "b" }, &.{ .{ .from = "a", .to = "b", .count = std.math.maxInt(usize) }, .{ .from = "a", .to = "b" } }));
}
test "aggregation at every depth counts isolated directories and root files" {
    var graph = try g.Graph.fromEdges(a, &.{ "main.zig", "src/a/x.zig", "src/b/y.zig", "alone/z.zig" }, &.{ .{ .from = "main.zig", .to = "src/a/x.zig" }, .{ .from = "src/a/x.zig", .to = "src/b/y.zig", .count = 2 } });
    defer graph.deinit();
    var root = try graph.aggregate(a, 0);
    defer root.deinit();
    try eq(1, root.paths.len);
    try f.edge(&root, ".", ".", .import, 3);
    var one = try graph.aggregate(a, 1);
    defer one.deinit();
    try eq(3, one.paths.len);
    try f.edge(&one, ".", "src", .import, 1);
    try f.edge(&one, "src", "src", .import, 2);
    var two = try graph.aggregate(a, 2);
    defer two.deinit();
    try eq(4, two.paths.len);
    try f.edge(&two, "src/a", "src/b", .import, 2);
}
test "results are deterministic when path and edge input order changes" {
    const paths = &[_][]const u8{ "c", "b", "a" };
    const edges = &[_]g.Edge{ .{ .from = "c", .to = "a" }, .{ .from = "a", .to = "b" }, .{ .from = "b", .to = "c" }, .{ .from = "a", .to = "b" } };
    var x = try g.Graph.fromEdges(a, paths, edges);
    defer x.deinit();
    var y = try g.Graph.fromEdges(a, &.{ "a", "b", "c" }, &.{ edges[3], edges[2], edges[1], edges[0] });
    defer y.deinit();
    try std.testing.expectEqualDeep(x.edges, y.edges);
    var ax = try x.analyze(a);
    defer ax.deinit();
    var ay = try y.analyze(a);
    defer ay.deinit();
    try std.testing.expectEqualDeep(ax.layers, ay.layers);
    try std.testing.expectEqualDeep(ax.cycles, ay.cycles);
    try std.testing.expectEqualDeep(ax.components, ay.components);
}
test "analysis and aggregate own their strings after original graph deinit" {
    var graph = try g.Graph.fromEdges(a, &.{ "src/a.zig", "lib/b.zig" }, &.{.{ .from = "src/a.zig", .to = "lib/b.zig" }});
    var analysis = try graph.analyze(a);
    defer analysis.deinit();
    var aggregate = try graph.aggregate(a, 1);
    defer aggregate.deinit();
    graph.deinit();
    try std.testing.expectEqualStrings("lib/b.zig", analysis.layers[0].path);
    try f.edge(&aggregate, "src", "lib", .import, 1);
}
fn allocationScenario(alloc: std.mem.Allocator) !void {
    var graph = try (f.Fixture{ .items = &.{
        .{ .path = "src/a.zig", .text = "const b = @import(\"b.zig\"); const p = @import(\"proto\"); const m = p.mirror;" },
        .{ .path = "src/b.zig", .text = "const a = @import(\"a.zig\");" },
        .{ .path = "package.json", .text = "{\"dependencies\":{\"x\":\"1\"}}" },
        .{ .path = "notes/a.md", .text = "[[b]]" },
        .{ .path = "notes/b.md", .text = "notes/a.md" },
    } }).scan(alloc, .{ .kinds = &.{ .import, .link, .asset } });
    defer graph.deinit();
    var analysis = try graph.analyze(alloc);
    defer analysis.deinit();
    var dirs = try graph.aggregate(alloc, 1);
    defer dirs.deinit();
    const findings = try graph.check(alloc, .{ .forbidden = &.{.{ .name = "all" }}, .no_cycles = "cycles" });
    defer alloc.free(findings);
    try expect(findings.len > 0);
}
test "every allocation failure releases scan graph analysis aggregation and findings" {
    try std.testing.checkAllAllocationFailures(a, allocationScenario, .{});
}
