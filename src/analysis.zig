//! Owned layers, components and cycle witnesses, independent of the graph.
const reach_module = @import("analysis/reach.zig");
const Storage_module = @import("graph/Storage.zig");
const analyze_module = @import("analysis/analyze.zig");
const std = @import("std");
const t = @import("types.zig");
const store = @import("analysis/State.zig");

/// Move this owner; do not copy it and deinitialize it twice.
// aegis: safe-type internals; docs/design.md: opaque analysis allocation ownership is not a copyable ID.
pub const Analysis = enum(usize) {
    _,

    /// What a query fails with: a path the analysis does not hold, or memory.
    pub const QueryError = error{ UnknownPath, OutOfMemory };
    /// What `init` fails with, as `Graph.fromEdges`.
    pub const InitError = Storage_module.FromEdgesError;
    pub fn deinit(self: *Analysis) void {
        store.get(self.*).deinit();
        self.* = undefined;
    }
    pub fn layers(self: *const Analysis) []const t.Layer {
        return store.get(self.*).layers;
    }
    pub fn cycles(self: *const Analysis) []const t.Cycle {
        return store.get(self.*).cycles;
    }
    /// All SCCs, including acyclic singletons, sorted by their first member.
    pub fn components(self: *const Analysis) []const []const []const u8 {
        return store.get(self.*).components;
    }
    /// Each node's coupling, in path order: its distinct dependents
    /// (`fan_in`) and dependencies (`fan_out`), itself not counted.
    pub fn coupling(self: *const Analysis) []const t.Coupling {
        return store.get(self.*).coupling;
    }
    /// Each directory above a node, in path order, with the files under it
    /// and the dependencies that cross its boundary: a dependency counts
    /// for every directory holding one end and not the other. The root is
    /// not listed.
    pub fn directoryCoupling(self: *const Analysis) []const t.Coupling {
        return store.get(self.*).directory_coupling;
    }
    pub const Direction = enum {
        /// What a file depends on.
        dependencies,
        /// What depends on a file.
        dependents,
    };
    /// The files `path` imports or links (`.dependencies`), or that import
    /// or link it (`.dependents`), in path order. The returned slice is the
    /// caller's to free with gpa.free; its paths belong to this analysis.
    /// A path the analysis does not hold is `error.UnknownPath`.
    pub fn direct(self: *const Analysis, gpa: std.mem.Allocator, path: []const u8, direction: Direction) QueryError![]const []const u8 {
        const state = store.get(self.*);
        const v = try position(state, path);
        const adjacency = if (direction == .dependencies) state.forward else state.backward;
        const result = try gpa.alloc([]const u8, adjacency.children(v).len);
        for (adjacency.children(v), result) |w, *dest| dest.* = state.paths[w];
        return result;
    }
    /// Every file a chain of one edge or more reaches from `starts`, in
    /// `direction`, in path order: a start is listed only when the chain
    /// returns to it. Memory is one mark and one queue entry per file,
    /// whatever the size of the closure. Free and borrow as `direct`.
    pub fn reach(self: *const Analysis, gpa: std.mem.Allocator, starts: []const []const u8, direction: Direction) QueryError![]const []const u8 {
        return closure(store.get(self.*), gpa, starts, direction, false);
    }
    /// The files a change to `changed` can affect: those files and every
    /// file that depends on one of them through any chain, in path order.
    /// A changed path the analysis does not hold is skipped, as a deleted
    /// file is. Free and borrow as `direct`.
    pub fn affected(self: *const Analysis, gpa: std.mem.Allocator, changed: []const []const u8) std.mem.Allocator.Error![]const []const u8 {
        return closure(store.get(self.*), gpa, changed, .dependents, true) catch |err| switch (err) {
            // unreachable: with `include` a path the analysis does not hold is skipped.
            error.UnknownPath => unreachable,
            error.OutOfMemory => |e| return e,
        };
    }
    /// The shortest chain of dependencies from `from` to `to`, both
    /// included, choosing the first path at each position among chains of
    /// that length; null when there is none. A path to itself needs a
    /// cycle. Free and borrow as `direct`.
    pub fn chain(self: *const Analysis, gpa: std.mem.Allocator, from: []const u8, to: []const u8) QueryError!?[]const []const u8 {
        const state = store.get(self.*);
        const source = try position(state, from);
        const target = try position(state, to);
        const walk = reach_module;
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        const s = scratch.allocator();
        const targets = try s.alloc(bool, state.paths.len);
        @memset(targets, false);
        targets[target] = true;
        const dist = try s.alloc(u32, state.paths.len);
        try walk.distances(s, state.backward, targets, .{}, dist);
        var nodes: std.ArrayList(u32) = .empty;
        if (try walk.chain(s, state.forward, dist, .{}, source, &nodes) == null) return null;
        const result = try gpa.alloc([]const u8, nodes.items.len);
        for (nodes.items, result) |v, *dest| dest.* = state.paths[v];
        return result;
    }
    /// Build an owned analysis using Graph.fromEdges validation and ordering.
    /// Paths and endpoints are normalized; duplicate paths and edges are merged.
    /// Returns InvalidPath for invalid or empty node paths, UnknownPath for absent
    /// endpoints, InvalidCount for zero counts, and CountOverflow when counts merge
    /// past usize. Results are sorted independently of input order and borrow nothing.
    pub fn init(gpa: std.mem.Allocator, paths: []const []const u8, edges: []const t.Edge) InitError!Analysis {
        const graph = try Storage_module.fromEdges(gpa, paths, edges);
        defer graph.deinit();
        return @fromBackingInt(@intCast(@intFromPtr(try analyze_module.analyze(graph, gpa)))); // safe: the owning handle retains the newly allocated analysis state until deinit.
    }
};

fn position(state: *const store, path: []const u8) error{UnknownPath}!u32 {
    const found = std.sort.binarySearch([]const u8, state.paths, path, struct {
        fn order(key: []const u8, item: []const u8) std.math.Order {
            return std.mem.order(u8, key, item);
        }
    }.order) orelse return error.UnknownPath;
    return @intCast(found);
}
fn closure(state: *const store, gpa: std.mem.Allocator, starts: []const []const u8, direction: Analysis.Direction, include: bool) Analysis.QueryError![]const []const u8 {
    const marks = try gpa.alloc(bool, state.paths.len);
    defer gpa.free(marks);
    @memset(marks, false);
    var positions: std.ArrayList(u32) = .empty;
    defer positions.deinit(gpa);
    for (starts) |path| {
        const v = position(state, path) catch |err| if (include) continue else return err;
        try positions.append(gpa, v);
    }
    const adjacency = if (direction == .dependencies) state.forward else state.backward;
    try reach_module.closure(gpa, adjacency, positions.items, marks);
    if (include) for (positions.items) |v| {
        marks[v] = true;
    };
    var count: usize = 0;
    for (marks) |mark| count += @intFromBool(mark);
    const result = try gpa.alloc([]const u8, count);
    count = 0;
    for (marks, 0..) |mark, v| if (mark) {
        result[count] = state.paths[v];
        count += 1;
    };
    return result;
}
