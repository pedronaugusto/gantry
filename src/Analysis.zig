//! Owned layers, components and cycle witnesses, independent of the graph.
const std = @import("std");
const t = @import("types.zig");
const store = @import("analysis_store.zig");

/// Move this owner; do not copy it and deinitialize it twice.
pub const Analysis = enum(usize) {
    _,
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
    /// Build an owned analysis using Graph.fromEdges validation and ordering.
    /// Paths and endpoints are normalized; duplicate paths and edges are merged.
    /// Returns InvalidPath for invalid or empty node paths, UnknownPath for absent
    /// endpoints, InvalidCount for zero counts, and CountOverflow when counts merge
    /// past usize. Results are sorted independently of input order and borrow nothing.
    pub fn init(gpa: std.mem.Allocator, paths: []const []const u8, edges: []const t.Edge) (std.mem.Allocator.Error || error{ InvalidPath, UnknownPath, InvalidCount, CountOverflow })!Analysis {
        const graph = try @import("graph_store.zig").fromEdges(gpa, paths, edges);
        defer graph.deinit();
        return @enumFromInt(@intFromPtr(try @import("analyze.zig").analyze(graph, gpa))); // safe: the owning handle retains the newly allocated analysis state until deinit.
    }
};
