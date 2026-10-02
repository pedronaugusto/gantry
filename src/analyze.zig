//! Iterative SCC discovery, condensation depths and real cycle witnesses.
const std = @import("std");
const t = @import("types.zig");
const Graph = @import("graph_store.zig");
const Adjacency = struct {
    offsets: []usize,
    targets: []usize,
    fn init(a: std.mem.Allocator, n: usize, from: []const usize, to: []const usize) !Adjacency {
        const offsets = try a.alloc(usize, n + 1);
        @memset(offsets, 0);
        for (from) |v| offsets[v + 1] += 1;
        for (1..n + 1) |i| offsets[i] += offsets[i - 1];
        const cursor = try a.dupe(usize, offsets);
        const targets = try a.alloc(usize, to.len);
        for (from, to) |v, w| {
            targets[cursor[v]] = w;
            cursor[v] += 1;
        }
        // Input edges are already ordered; reverse adjacency need not be.
        return .{ .offsets = offsets, .targets = targets };
    }
    fn children(self: Adjacency, v: usize) []const usize {
        return self.targets[self.offsets[v]..self.offsets[v + 1]];
    }
};
const Frame = struct { node: usize, next: usize };
/// The graph supplies unique sorted paths and validated, coalesced edges.
pub fn analyze(g: *const Graph, gpa: std.mem.Allocator) std.mem.Allocator.Error!*@import("analysis_store.zig") {
    const paths = g.paths;
    const edges = g.edges;
    const self = try @import("analysis_store.zig").init(gpa);
    errdefer self.deinit();
    const a = self.arena.allocator();
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const s = scratch.allocator();
    const n = paths.len;
    const owned = try a.alloc([]const u8, n);
    var ids: std.StringHashMapUnmanaged(usize) = .empty;
    for (paths, owned, 0..) |path, *dest, i| {
        dest.* = try a.dupe(u8, path);
        try ids.put(s, path, i);
    }
    const from = try s.alloc(usize, edges.len);
    const to = try s.alloc(usize, edges.len);
    for (edges, from, to) |edge, *v, *w| {
        v.* = ids.get(edge.from).?;
        w.* = ids.get(edge.to).?;
    }
    const adj = try Adjacency.init(s, n, from, to);
    const rev = try Adjacency.init(s, n, to, from);
    const seen = try s.alloc(bool, n);
    @memset(seen, false);
    var frames: std.ArrayList(Frame) = .empty;
    var finish: std.ArrayList(usize) = .empty;
    for (0..n) |start| {
        if (seen[start]) continue;
        seen[start] = true;
        try frames.append(s, .{ .node = start, .next = 0 });
        while (frames.items.len > 0) {
            const f = &frames.items[frames.items.len - 1];
            const children = adj.children(f.node);
            if (f.next < children.len) {
                const child = children[f.next];
                f.next += 1;
                if (!seen[child]) {
                    seen[child] = true;
                    try frames.append(s, .{ .node = child, .next = 0 });
                }
            } else {
                try finish.append(s, f.node);
                _ = frames.pop();
            }
        }
    }
    @memset(seen, false);
    var groups: std.ArrayList([]usize) = .empty;
    var stack: std.ArrayList(usize) = .empty;
    var f = finish.items.len;
    while (f > 0) {
        f -= 1;
        const start = finish.items[f];
        if (seen[start]) continue;
        var members: std.ArrayList(usize) = .empty;
        seen[start] = true;
        try stack.append(s, start);
        while (stack.pop()) |v| {
            try members.append(s, v);
            for (rev.children(v)) |w| if (!seen[w]) {
                seen[w] = true;
                try stack.append(s, w);
            };
        }
        std.mem.sort(usize, members.items, {}, std.sort.asc(usize));
        try groups.append(s, try members.toOwnedSlice(s));
    }
    std.mem.sort([]usize, groups.items, {}, struct {
        fn less(_: void, x: []usize, y: []usize) bool {
            return x[0] < y[0];
        }
    }.less);
    const component = try s.alloc(usize, n);
    const components = try a.alloc([]const []const u8, groups.items.len);
    var cycles: std.ArrayList(t.Cycle) = .empty;
    // One reusable BFS workspace for every witness; no O(V * SCCs) clearing.
    const parent = try s.alloc(usize, n);
    const visited = try s.alloc(usize, n);
    @memset(visited, 0);
    for (groups.items, components, 0..) |members, *dest, id| {
        const names = try a.alloc([]const u8, members.len);
        for (members, names) |v, *name| {
            component[v] = id;
            name.* = owned[v];
        }
        dest.* = names;
    }
    for (groups.items, components, 0..) |members, names, id| {
        const start = members[0];
        var first: ?usize = null;
        for (adj.children(start)) |w| if (component[w] == id) {
            first = w;
            break;
        };
        if (members.len == 1 and (first == null or first.? != start)) continue;
        const next = first.?;
        var witness: std.ArrayList([]const u8) = .empty;
        try witness.append(a, owned[start]);
        if (next != start) {
            var queue: std.ArrayList(usize) = .empty;
            const stamp = id + 1;
            visited[next] = stamp;
            parent[next] = next;
            try queue.append(s, next);
            var head: usize = 0;
            while (head < queue.items.len and visited[start] != stamp) : (head += 1) {
                const v = queue.items[head];
                for (adj.children(v)) |w| if (component[w] == id and visited[w] != stamp) {
                    visited[w] = stamp;
                    parent[w] = v;
                    try queue.append(s, w);
                };
            }
            var route: std.ArrayList(usize) = .empty;
            var v = start;
            while (v != next) {
                v = parent[v];
                try route.append(s, v);
            }
            var k = route.items.len;
            while (k > 0) {
                k -= 1;
                try witness.append(a, owned[route.items[k]]);
            }
        }
        try witness.append(a, owned[start]);
        try cycles.append(a, .{ .members = names, .path = try witness.toOwnedSlice(a) });
    }
    const m = groups.items.len;
    const indegree = try s.alloc(usize, m);
    const depth = try s.alloc(usize, m);
    @memset(indegree, 0);
    @memset(depth, 0);
    var cf: std.ArrayList(usize) = .empty;
    var ct: std.ArrayList(usize) = .empty;
    for (from, to) |v, w| if (component[v] != component[w]) {
        try cf.append(s, component[v]);
        try ct.append(s, component[w]);
        indegree[component[w]] += 1;
    };
    const dag = try Adjacency.init(s, m, cf.items, ct.items);
    var queue: std.ArrayList(usize) = .empty;
    for (indegree, 0..) |d, id| if (d == 0) {
        try queue.append(s, id);
    };
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const v = queue.items[head];
        for (dag.children(v)) |w| {
            depth[w] = @max(depth[w], depth[v] + 1);
            indegree[w] -= 1;
            if (indegree[w] == 0) try queue.append(s, w);
        }
    }
    const layers = try a.alloc(t.Layer, n);
    for (owned, layers, 0..) |path, *layer, id| layer.* = .{ .path = path, .depth = depth[component[id]] };
    self.layers = layers;
    self.components = components;
    self.cycles = try cycles.toOwnedSlice(a);
    return self;
}
