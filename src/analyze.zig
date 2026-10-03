//! Iterative SCC discovery, condensation depths and real cycle witnesses.
const std = @import("std");
const t = @import("types.zig");
const Graph = @import("graph_store.zig");
const Adjacency = @import("reach.zig").Adjacency;
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
    if (n >= std.math.maxInt(u32)) return error.OutOfMemory;
    const owned = try a.alloc([]const u8, n);
    var ids: std.StringHashMapUnmanaged(u32) = .empty;
    try ids.ensureTotalCapacity(s, @intCast(n));
    for (paths, owned, 0..) |path, *dest, i| {
        dest.* = try a.dupe(u8, path);
        ids.putAssumeCapacity(path, @intCast(i));
    }
    // One pair per importer and dependency: edges of several kinds between
    // the same files are one dependency here. Edges are sorted by path.
    var from: std.ArrayList(u32) = .empty;
    var to: std.ArrayList(u32) = .empty;
    try from.ensureTotalCapacity(s, edges.len);
    try to.ensureTotalCapacity(s, edges.len);
    for (edges) |edge| {
        const v = ids.get(edge.from).?;
        const w = ids.get(edge.to).?;
        if (from.items.len > 0 and from.items[from.items.len - 1] == v and to.items[to.items.len - 1] == w) continue;
        from.appendAssumeCapacity(v);
        to.appendAssumeCapacity(w);
    }
    const adj = try Adjacency.init(a, n, from.items, to.items, false);
    const rev = try Adjacency.init(a, n, to.items, from.items, false);
    self.paths = owned;
    self.forward = adj;
    self.backward = rev;
    self.coupling = try fileCoupling(a, owned, from.items, to.items);
    self.directory_coupling = try directoryCoupling(a, s, owned, from.items, to.items);
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
    var cf: std.ArrayList(u32) = .empty;
    var ct: std.ArrayList(u32) = .empty;
    for (from.items, to.items) |v, w| if (component[v] != component[w]) {
        try cf.append(s, @intCast(component[v]));
        try ct.append(s, @intCast(component[w]));
        indegree[component[w]] += 1;
    };
    const dag = try Adjacency.init(s, m, cf.items, ct.items, false);
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

/// Each node's distinct dependents and dependencies, itself not counted.
fn fileCoupling(a: std.mem.Allocator, paths: []const []const u8, from: []const u32, to: []const u32) ![]const t.Coupling {
    const result = try a.alloc(t.Coupling, paths.len);
    for (paths, result) |path, *c| c.* = .{ .path = path, .fan_in = 0, .fan_out = 0 };
    for (from, to) |v, w| if (v != w) {
        result[v].fan_out += 1;
        result[w].fan_in += 1;
    };
    return result;
}
/// Every directory above a node, as a slice of the node's own path, with
/// the dependencies that cross its boundary: a pair counts for each
/// directory that holds one end and not the other.
fn directoryCoupling(a: std.mem.Allocator, s: std.mem.Allocator, paths: []const []const u8, from: []const u32, to: []const u32) ![]const t.Coupling {
    var names: std.ArrayList([]const u8) = .empty;
    // Each node's directories, outermost first, as one list with offsets.
    // Paths are sorted, so a directory's nodes are one run: the previous
    // node's directories, as a stack, give every directory its number once.
    const offsets = try s.alloc(u32, paths.len + 1);
    var chains: std.ArrayList(u32) = .empty;
    var stack: std.ArrayList(u32) = .empty;
    offsets[0] = 0;
    for (paths, 0..) |path, v| {
        var depth: usize = 0;
        var at: usize = 0;
        while (std.mem.indexOfScalarPos(u8, path, at, '/')) |slash| : (at = slash + 1) {
            const name = path[0..slash];
            if (depth < stack.items.len and std.mem.eql(u8, names.items[stack.items[depth]], name)) {
                depth += 1;
                continue;
            }
            stack.shrinkRetainingCapacity(depth);
            try stack.append(s, @intCast(names.items.len));
            try names.append(s, name);
            depth += 1;
        }
        stack.shrinkRetainingCapacity(depth);
        try chains.appendSlice(s, stack.items);
        offsets[v + 1] = @intCast(chains.items.len);
    }
    const counts = try s.alloc(t.Coupling, names.items.len);
    for (names.items, counts) |name, *c| c.* = .{ .path = name, .files = 0, .fan_in = 0, .fan_out = 0 };
    for (paths, 0..) |_, v| for (chains.items[offsets[v]..offsets[v + 1]]) |d| {
        counts[d].files += 1;
    };
    for (from, to) |v, w| {
        if (v == w) continue;
        const outer = chains.items[offsets[v]..offsets[v + 1]];
        const inner = chains.items[offsets[w]..offsets[w + 1]];
        var shared: usize = 0;
        while (shared < outer.len and shared < inner.len and outer[shared] == inner[shared]) shared += 1;
        for (outer[shared..]) |d| counts[d].fan_out += 1;
        for (inner[shared..]) |d| counts[d].fan_in += 1;
    }
    std.mem.sort(t.Coupling, counts, {}, struct {
        fn less(_: void, x: t.Coupling, y: t.Coupling) bool {
            return std.mem.order(u8, x.path, y.path) == .lt;
        }
    }.less);
    return a.dupe(t.Coupling, counts);
}
