//! Owned layers, components and cycle witnesses, independent of the graph.
const std = @import("std");
const t = @import("types.zig");
const Analysis = @This();
allocator: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
layers: []const t.Layer = &.{},
cycles: []const t.Cycle = &.{},
/// All SCCs, including acyclic singletons, sorted by their first member.
components: []const []const []const u8 = &.{},

pub fn deinit(self: *Analysis) void {
    self.arena.deinit();
    self.* = undefined;
}

/// Build an owned analysis using Graph.fromEdges validation and ordering.
/// Paths and endpoints are normalized; duplicate paths and edges are merged.
/// Returns InvalidPath for invalid or empty node paths, UnknownPath for absent
/// endpoints, InvalidCount for zero counts, and CountOverflow when counts merge
/// past usize. Results are sorted independently of input order and borrow nothing.
pub fn init(gpa: std.mem.Allocator, paths: []const []const u8, edges: []const t.Edge) (std.mem.Allocator.Error || error{ InvalidPath, UnknownPath, InvalidCount, CountOverflow })!Analysis {
    var graph = try @import("Graph.zig").fromEdges(gpa, paths, edges);
    defer graph.deinit();
    return graph.analyze(gpa);
}
