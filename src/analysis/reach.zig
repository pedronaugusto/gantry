//! Walks over a graph held as adjacency arrays of node positions. The
//! caller numbers nodes by sorted path, so the lowest position is the
//! first path; every choice below takes the lowest, which makes results
//! independent of input order.
const std = @import("std");

/// Node v's neighbours are `targets[offsets[v]..offsets[v + 1]]`, in the
/// order the builder listed them; `labels` (empty, or one per target)
/// carries what the builder attached to each, such as an edge's index.
pub const Adjacency = struct {
    offsets: []u32,
    targets: []u32,
    labels: []u32 = &.{},

    /// A stable counting sort of `from`/`to` pairs by `from`. With
    /// `labeled`, each neighbour carries its pair's index.
    pub fn init(a: std.mem.Allocator, n: usize, from: []const u32, to: []const u32, labeled: bool) !Adjacency {
        std.debug.assert(from.len == to.len);
        for (from, to) |v, w| {
            std.debug.assert(v < n);
            std.debug.assert(w < n);
        }
        if (n >= std.math.maxInt(u32) or from.len >= std.math.maxInt(u32)) return error.OutOfMemory;
        const offsets = try a.alloc(u32, n + 1);
        @memset(offsets, 0);
        for (from) |v| offsets[v + 1] += 1;
        for (1..n + 1) |i| offsets[i] += offsets[i - 1];
        const cursor = try a.dupe(u32, offsets[0..n]);
        defer a.free(cursor);
        const targets = try a.alloc(u32, to.len);
        const labels: []u32 = if (labeled) try a.alloc(u32, to.len) else &.{};
        for (from, to, 0..) |v, w, i| {
            targets[cursor[v]] = w;
            if (labeled) labels[cursor[v]] = @intCast(i);
            cursor[v] += 1;
        }
        std.debug.assert(offsets[0] == 0);
        std.debug.assert(offsets[n] == targets.len);
        std.debug.assert(labels.len == 0 or labels.len == targets.len);
        return .{ .offsets = offsets, .targets = targets, .labels = labels };
    }
    pub fn children(self: Adjacency, v: usize) []const u32 {
        std.debug.assert(v + 1 < self.offsets.len);
        std.debug.assert(self.offsets[v] <= self.offsets[v + 1]);
        std.debug.assert(self.offsets[v + 1] <= self.targets.len);
        return self.targets[self.offsets[v]..self.offsets[v + 1]];
    }
    /// The label of the neighbour at `index` in `targets`, 0 unlabelled.
    pub fn label(self: Adjacency, index: usize) u32 {
        std.debug.assert(index < self.targets.len);
        std.debug.assert(self.labels.len == 0 or self.labels.len == self.targets.len);
        return if (self.labels.len == 0) 0 else self.labels[index];
    }
};

/// Marks every node a walk of one edge or more reaches from `starts`.
/// `marks` holds one entry per node, all false on entry.
pub fn closure(a: std.mem.Allocator, adjacency: Adjacency, starts: []const u32, marks: []bool) !void {
    std.debug.assert(adjacency.offsets.len == marks.len + 1);
    for (marks) |marked| std.debug.assert(!marked);
    var queue: std.ArrayList(u32) = .empty;
    defer queue.deinit(a);
    for (starts) |v| for (adjacency.children(v)) |w| if (!marks[w]) {
        marks[w] = true;
        try queue.append(a, w);
    };
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        for (adjacency.children(queue.items[head])) |w| if (!marks[w]) {
            marks[w] = true;
            try queue.append(a, w);
        };
    }
}

pub const unreached = std.math.maxInt(u32);

/// The edges a walk may follow and the nodes it may pass through, by
/// label and by position.
pub const Filter = struct {
    /// One per label; null follows every edge.
    follow: ?[]const bool = null,
    /// One per node; null passes through every node.
    passable: ?[]const bool = null,
    fn edge(f: Filter, label: u32) bool {
        return if (f.follow) |follow| follow[label] else true;
    }
    fn through(f: Filter, v: u32) bool {
        return if (f.passable) |passable| passable[v] else true;
    }
};

/// Distances to the nearest target, walking `backward` (each node's
/// predecessors, labelled like `forward`) from every target at once.
/// Only targets and passable nodes get a distance.
pub fn distances(a: std.mem.Allocator, backward: Adjacency, targets: []const bool, filter: Filter, dist: []u32) !void {
    std.debug.assert(backward.offsets.len == dist.len + 1);
    std.debug.assert(targets.len == dist.len);
    if (filter.passable) |passable| std.debug.assert(passable.len == dist.len);
    @memset(dist, unreached);
    var queue: std.ArrayList(u32) = .empty;
    defer queue.deinit(a);
    for (targets, 0..) |target, v| if (target) {
        dist[v] = 0;
        try queue.append(a, @intCast(v));
    };
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const v = queue.items[head];
        for (backward.offsets[v]..backward.offsets[v + 1]) |k| {
            const p = backward.targets[k];
            if (dist[p] != unreached or !filter.edge(backward.label(k)) or !filter.through(p)) continue;
            dist[p] = dist[v] + 1;
            try queue.append(a, p);
        }
    }
}

/// One step of a shortest chain from `v`: the lowest neighbour nearest a
/// target, with the label of the first edge to it, or null when no
/// followed edge leads to one. Inside a chain `bound` is `dist[v]` and the
/// step must go one nearer; from its start it is `unreached`.
pub fn step(forward: Adjacency, dist: []const u32, filter: Filter, v: u32, bound: u32) ?struct { node: u32, label: u32 } {
    std.debug.assert(forward.offsets.len == dist.len + 1);
    std.debug.assert(v < dist.len);
    var best: ?struct { node: u32, label: u32, dist: u32 } = null;
    for (forward.offsets[v]..forward.offsets[v + 1]) |k| {
        const w = forward.targets[k];
        const label = forward.label(k);
        if (dist[w] == unreached or !filter.edge(label)) continue;
        const d = dist[w] + 1;
        if (bound != unreached and d != bound) continue;
        if (best) |b| if (d > b.dist or (d == b.dist and w >= b.node)) continue;
        best = .{ .node = w, .label = label, .dist = d };
    }
    const found = best orelse return null;
    return .{ .node = found.node, .label = found.label };
}

/// The shortest chain from `start` to a target, `start` first, appended
/// to `out`; the lowest node at each position among the shortest. It has
/// one edge or more even when `start` is itself a target. Returns the
/// first edge's label, or null when no target is reached.
pub fn chain(a: std.mem.Allocator, forward: Adjacency, dist: []const u32, filter: Filter, start: u32, out: *std.ArrayList(u32)) !?u32 {
    const first = step(forward, dist, filter, start, unreached) orelse return null;
    try out.append(a, start);
    var v = first.node;
    try out.append(a, v);
    while (dist[v] != 0) {
        v = (step(forward, dist, filter, v, dist[v]) orelse unreachable).node; // a node at distance d has a neighbour at d - 1
        try out.append(a, v);
    }
    return first.label;
}
