//! A graph owns every path and slice it exposes until deinit.
const std = @import("std");
const t = @import("types.zig");
const Graph = @This();
allocator: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
paths: []const []const u8 = &.{},
edges: []const t.Edge = &.{},
dependencies: []const t.Dependency = &.{},
references: []const t.Reference = &.{},
/// Selected files for which the caller returned null; never silently omitted.
unread: []const []const u8 = &.{},
go_files: []const @import("go_build.zig").File = &.{},
files: std.StringHashMapUnmanaged(void) = .empty,

pub fn init(gpa: std.mem.Allocator, paths: []const []const u8) !Graph {
    var g: Graph = .{ .allocator = gpa, .arena = .init(gpa) };
    errdefer g.deinit();
    const a = g.arena.allocator();
    var list: std.ArrayList([]const u8) = .empty;
    for (paths) |raw| {
        const path = try @import("path.zig").normalize(a, raw);
        if (path.len == 0) return error.InvalidPath;
        const entry = try g.files.getOrPut(a, path);
        if (!entry.found_existing) try list.append(a, path);
    }
    std.mem.sort([]const u8, list.items, {}, t.stringsLess);
    g.paths = try list.toOwnedSlice(a);
    return g;
}
pub fn deinit(g: *Graph) void {
    g.arena.deinit();
    g.* = undefined;
}
/// Build a graph from caller edges. Endpoints must be among paths.
pub fn fromEdges(gpa: std.mem.Allocator, paths: []const []const u8, edges: []const t.Edge) !Graph {
    var g = try init(gpa, paths);
    errdefer g.deinit();
    const a = g.arena.allocator();
    const owned = try a.alloc(t.Edge, edges.len);
    for (edges, owned) |edge, *dest| {
        if (edge.count == 0) return error.InvalidCount;
        const from = try @import("path.zig").normalize(a, edge.from);
        const to = try @import("path.zig").normalize(a, edge.to);
        if (!g.files.contains(from) or !g.files.contains(to)) return error.UnknownPath;
        dest.* = .{ .from = from, .to = to, .kind = edge.kind, .count = edge.count };
    }
    g.edges = try coalesce(a, owned);
    return g;
}
/// Directory nodes at depth (0 is the root, 1 the first component).
/// The returned graph is independent of this one, with no manifest references.
/// Directory self edges are retained: they describe coupling within a directory.
pub fn aggregate(g: *const Graph, gpa: std.mem.Allocator, depth: usize) !Graph {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const paths = try a.alloc([]const u8, g.paths.len);
    for (g.paths, paths) |path, *dest| dest.* = @import("path.zig").directory(path, depth);
    const edges = try a.alloc(t.Edge, g.edges.len);
    for (g.edges, edges) |edge, *dest| dest.* = .{ .from = @import("path.zig").directory(edge.from, depth), .to = @import("path.zig").directory(edge.to, depth), .kind = edge.kind, .count = edge.count };
    // '.' is a graph node for the root, not a file path.
    var result = try Graph.init(gpa, &.{});
    errdefer result.deinit();
    const ra = result.arena.allocator();
    var list: std.ArrayList([]const u8) = .empty;
    for (paths) |path| {
        const key = try ra.dupe(u8, path);
        const entry = try result.files.getOrPut(ra, key);
        if (!entry.found_existing) try list.append(ra, key);
    }
    std.mem.sort([]const u8, list.items, {}, t.stringsLess);
    result.paths = try list.toOwnedSlice(ra);
    const copied = try ra.alloc(t.Edge, edges.len);
    for (edges, copied) |edge, *dest| {
        dest.* = edge;
        dest.from = try ra.dupe(u8, edge.from);
        dest.to = try ra.dupe(u8, edge.to);
    }
    result.edges = try coalesce(ra, copied);
    return result;
}
/// Analysis owns its results independently of the graph.
pub fn analyze(g: *const Graph, gpa: std.mem.Allocator) !@import("Analysis.zig") {
    return @import("analyze.zig").analyze(g, gpa);
}
/// Findings borrow graph paths and rule names. Free only the returned slice.
pub fn check(g: *const Graph, gpa: std.mem.Allocator, rules: @import("rules.zig").Rules) ![]const @import("rules.zig").Violation {
    return @import("rules.zig").check(g, gpa, rules);
}
pub fn coalesce(_: std.mem.Allocator, edges: []t.Edge) ![]const t.Edge {
    std.mem.sort(t.Edge, edges, {}, t.edgesLess);
    var n: usize = 0;
    for (edges) |edge| {
        if (n > 0 and std.mem.eql(u8, edges[n - 1].from, edge.from) and std.mem.eql(u8, edges[n - 1].to, edge.to) and edges[n - 1].kind == edge.kind) {
            edges[n - 1].count = std.math.add(usize, edges[n - 1].count, edge.count) catch return error.CountOverflow;
        } else {
            edges[n] = edge;
            n += 1;
        }
    }
    return edges[0..n];
}
