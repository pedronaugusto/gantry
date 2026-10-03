const std = @import("std");
const g = @import("gantry.zig");
const f = @import("test_support.zig");
const a = std.testing.allocator;
const eq = std.testing.expectEqual;

fn expectPaths(want: []const []const u8, got: []const []const u8) !void {
    defer a.free(got);
    try eq(want.len, got.len);
    for (want, got) |w, x| try std.testing.expectEqualStrings(w, x);
}

const files = &[_][]const u8{ "a/w.zig", "a/x.zig", "b/y.zig", "b/z.zig", "b/c/q.zig", "r.zig" };
const edges = &[_]g.Edge{
    .{ .from = "a/x.zig", .to = "b/y.zig" },
    .{ .from = "a/x.zig", .to = "b/z.zig" },
    .{ .from = "a/x.zig", .to = "b/z.zig", .kind = .type_only, .count = 3 },
    .{ .from = "a/w.zig", .to = "a/x.zig" },
    .{ .from = "r.zig", .to = "a/x.zig" },
    .{ .from = "b/c/q.zig", .to = "b/y.zig" },
    .{ .from = "b/y.zig", .to = "b/c/q.zig" },
};

test "queries list direct and transitive neighbours, affected files and shortest chains" {
    var analysis = try g.Analysis.init(a, files, edges);
    defer analysis.deinit();
    try expectPaths(&.{ "a/w.zig", "r.zig" }, try analysis.direct(a, "a/x.zig", .dependents));
    try expectPaths(&.{ "b/y.zig", "b/z.zig" }, try analysis.direct(a, "a/x.zig", .dependencies));
    try expectPaths(&.{ "a/x.zig", "b/c/q.zig", "b/y.zig", "b/z.zig" }, try analysis.reach(a, &.{"a/w.zig"}, .dependencies));
    // A start is listed only when a chain returns to it.
    try expectPaths(&.{ "b/c/q.zig", "b/y.zig" }, try analysis.reach(a, &.{"b/y.zig"}, .dependencies));
    try expectPaths(&.{ "a/w.zig", "a/x.zig", "r.zig" }, try analysis.reach(a, &.{ "b/z.zig", "a/x.zig" }, .dependents));
    // A deleted file is skipped; the changed files themselves are affected.
    try expectPaths(&.{ "a/w.zig", "a/x.zig", "b/z.zig", "r.zig" }, try analysis.affected(a, &.{ "b/z.zig", "gone.zig" }));
    try expectPaths(&.{}, try analysis.affected(a, &.{}));
    try expectPaths(&.{ "a/w.zig", "a/x.zig", "b/y.zig", "b/c/q.zig" }, (try analysis.chain(a, "a/w.zig", "b/c/q.zig")).?);
    try expectPaths(&.{ "b/y.zig", "b/c/q.zig", "b/y.zig" }, (try analysis.chain(a, "b/y.zig", "b/y.zig")).?);
    try eq(null, try analysis.chain(a, "b/z.zig", "a/w.zig"));
    try eq(null, try analysis.chain(a, "a/w.zig", "a/w.zig"));
    try std.testing.expectError(error.UnknownPath, analysis.direct(a, "gone.zig", .dependents));
    try std.testing.expectError(error.UnknownPath, analysis.reach(a, &.{"gone.zig"}, .dependents));
    try std.testing.expectError(error.UnknownPath, analysis.chain(a, "a/w.zig", "gone.zig"));
}

test "generated graphs agree with an independent closure and shortest chains" {
    const n = 10;
    const paths = &[_][]const u8{ "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" };
    const far = std.math.maxInt(usize) / 4;
    var random: std.Random.DefaultPrng = .init(0x7175657279);
    for (0..128) |_| {
        var list: std.ArrayList(g.Edge) = .empty;
        defer list.deinit(a);
        var direct: [n][n]bool = @splat(@splat(false));
        for (0..n) |v| for (0..n) |w| if (random.random().uintLessThan(u8, 10) < 2) {
            direct[v][w] = true;
            try list.append(a, .{ .from = paths[v], .to = paths[w] });
        };
        // Floyd-Warshall over chains of zero edges or more.
        var dist: [n][n]usize = @splat(@splat(far));
        for (0..n) |v| for (0..n) |w| {
            if (v == w) dist[v][w] = 0 else if (direct[v][w]) dist[v][w] = 1;
        };
        for (0..n) |k| for (0..n) |v| for (0..n) |w| {
            dist[v][w] = @min(dist[v][w], dist[v][k] + dist[k][w]);
        };
        var graph = try g.Graph.fromEdges(a, paths, list.items);
        defer graph.deinit();
        var analysis = try graph.analyze(a);
        defer analysis.deinit();
        for (0..n) |v| {
            // Reached by one edge or more: a step, then any chain.
            var forward: [n]bool = @splat(false);
            var backward: [n]bool = @splat(false);
            for (0..n) |w| for (0..n) |y| {
                if (direct[v][y] and dist[y][w] < far) forward[w] = true;
                if (direct[w][y] and dist[y][v] < far) backward[w] = true;
            };
            const reached = try analysis.reach(a, &.{paths[v]}, .dependencies);
            defer a.free(reached);
            var count: usize = 0;
            for (forward) |r| count += @intFromBool(r);
            try eq(count, reached.len);
            for (reached) |p| try std.testing.expect(forward[p[0] - '0']);
            const affected = try analysis.affected(a, &.{paths[v]});
            defer a.free(affected);
            backward[v] = true;
            count = 0;
            for (backward) |r| count += @intFromBool(r);
            try eq(count, affected.len);
            for (affected) |p| try std.testing.expect(backward[p[0] - '0']);
            for (0..n) |w| {
                // The lowest first step among the shortest, then the lowest
                // next step one nearer the end.
                var first: ?usize = null;
                for (0..n) |y| if (direct[v][y] and dist[y][w] < far and (first == null or dist[y][w] < dist[first.?][w])) {
                    first = y;
                };
                const found = try analysis.chain(a, paths[v], paths[w]);
                if (first == null) {
                    try eq(null, found);
                    continue;
                }
                const route = found.?;
                defer a.free(route);
                try eq(dist[first.?][w] + 2, route.len);
                try eq(v, route[0][0] - '0');
                var x = first.?;
                try eq(x, route[1][0] - '0');
                for (route[2..]) |p| {
                    var next: ?usize = null;
                    for (0..n) |y| if (direct[x][y] and dist[y][w] + 1 == dist[x][w]) {
                        next = y;
                        break;
                    };
                    x = next.?;
                    try eq(x, p[0] - '0');
                }
                try eq(w, x);
            }
        }
    }
}

test "affected and reach hold one mark and one queue entry per file on a 50,000-file graph" {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const s = arena.allocator();
    const n = 50_000;
    const paths = try s.alloc([]const u8, n);
    var list: std.ArrayList(g.Edge) = .empty;
    for (paths, 0..) |*p, i| p.* = try std.fmt.allocPrint(s, "g{d}/f{d}.zig", .{ i / 10, i % 10 });
    // Groups of ten in a cycle, each group's first file importing the
    // previous group's sixth: every file depends on every earlier group.
    for (0..n) |i| {
        const group = i / 10;
        const member = i % 10;
        try list.append(s, .{ .from = paths[i], .to = paths[group * 10 + if (member == 0) 9 else member - 1] });
        if (member == 0 and group > 0) try list.append(s, .{ .from = paths[i], .to = paths[(group - 1) * 10 + 5] });
    }
    var analysis = try g.Analysis.init(a, paths, list.items);
    defer analysis.deinit();
    var counter: f.Peak = .{ .child = a };
    const everything = try analysis.affected(counter.allocator(), &.{"g0/f0.zig"});
    defer counter.allocator().free(everything);
    try eq(n, everything.len);
    // The result's n slices, n marks and a queue of at most n positions
    // grown by halves: no per-pair or per-start storage.
    const bound = n * (@sizeOf([]const u8) + 1 + 2 * @sizeOf(u32)) + 4096;
    try std.testing.expect(counter.peak < bound);
    var many: f.Peak = .{ .child = a };
    const changed = try s.alloc([]const u8, n / 2);
    for (changed, 0..) |*p, i| p.* = paths[2 * i];
    const all = try analysis.affected(many.allocator(), changed);
    defer many.allocator().free(all);
    try eq(n, all.len);
    try std.testing.expect(many.peak < bound + n / 2 * @sizeOf(u32) * 2);
}
