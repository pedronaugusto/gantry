//! An owned graph. Results are read only and live until deinit.
const std = @import("std");
const t = @import("types.zig");
const store = @import("graph_store.zig");

/// Move this owner; do not copy it and deinitialize it twice.
pub const Graph = enum(usize) {
    _,

    pub fn init(gpa: std.mem.Allocator, node_paths: []const []const u8) !Graph {
        return store.owner(try store.init(gpa, node_paths));
    }
    /// Copies, validates, sorts and coalesces caller edges. Endpoints must be among paths.
    pub fn fromEdges(gpa: std.mem.Allocator, node_paths: []const []const u8, input_edges: []const t.Edge) !Graph {
        return store.owner(try store.fromEdges(gpa, node_paths, input_edges));
    }
    pub fn deinit(g: *Graph) void {
        store.get(g.*).deinit();
        g.* = undefined;
    }
    pub fn paths(g: *const Graph) []const []const u8 {
        return store.get(g.*).paths;
    }
    pub fn edges(g: *const Graph) []const t.Edge {
        return store.get(g.*).edges;
    }
    pub fn dependencies(g: *const Graph) []const t.Dependency {
        return store.get(g.*).dependencies;
    }
    pub fn references(g: *const Graph) []const t.Reference {
        return store.get(g.*).references;
    }
    /// Detectable import constructs omitted by lexical recovery, ordered by
    /// source path and byte offset. These slices belong to this graph.
    pub fn unsupported(g: *const Graph) []const t.UnsupportedReference {
        return store.get(g.*).unsupported;
    }
    /// Selected files for which the caller returned null, each listed once.
    pub fn unread(g: *const Graph) []const []const u8 {
        return store.get(g.*).unread;
    }
    pub fn goFiles(g: *const Graph) []const @import("go_build.zig").File {
        return store.get(g.*).go_files;
    }
    /// Membership by exact normalized spelling, including directory nodes in aggregates.
    pub fn contains(g: *const Graph, path: []const u8) bool {
        return store.get(g.*).files.contains(path);
    }
    /// Directory nodes at depth (0 is the root, 1 the first component).
    /// The result is independent of this graph, with no manifest references.
    /// Unsupported imports retain their original source paths and byte offsets.
    /// Directory self edges are retained as coupling within a directory.
    pub fn aggregate(g: *const Graph, gpa: std.mem.Allocator, depth: usize) !Graph {
        return store.owner(try store.get(g.*).aggregate(gpa, depth));
    }
    /// Analysis owns its results independently of the graph.
    pub fn analyze(g: *const Graph, gpa: std.mem.Allocator) !@import("Analysis.zig").Analysis {
        return store.get(g.*).analyze(gpa);
    }
    /// Findings borrow graph storage, rule names and required-path strings.
    /// Keep the graph and those caller strings alive until findings are freed.
    /// Free only the returned slice with gpa.free.
    pub fn check(g: *const Graph, gpa: std.mem.Allocator, rules: @import("rules.zig").Rules) ![]const @import("rules.zig").Violation {
        return @import("rules.zig").check(g, gpa, rules);
    }
};
