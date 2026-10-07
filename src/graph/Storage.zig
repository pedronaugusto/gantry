//! A graph owns every path and slice it exposes until deinit.
const check_module = @import("../rules/check.zig");
const build_module = @import("../lang/go/build.zig");
const diagnostic_module = @import("../scan/diagnostic.zig");
const path_module = @import("../path.zig");
const std = @import("std");
const t = @import("../types.zig");
const Storage = @This();
allocator: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
paths: []const []const u8 = &.{},
edges: []const t.Edge = &.{},
dependencies: []const t.Dependency = &.{},
references: []const t.Reference = &.{},
unsupported: []const t.UnsupportedReference = &.{},
tokens: []const t.Token = &.{},
/// The tokens the scan recorded occurrences for.
scanned_tokens: []const ScannedToken = &.{},
/// Whether the scan read manifest declarations, which dependency rules need.
manifests: bool = false,
/// Selected files for which the caller returned null; never silently omitted.
unread: []const []const u8 = &.{},
/// Selected files read but not usable as their format.
invalid: []const diagnostic_module.InvalidFile = &.{},
go_files: []const build_module.File = &.{},
files: std.StringHashMapUnmanaged(void) = .empty,

/// What building a graph from paths fails with: a path `path.normalize` refuses, or memory.
pub const InitError = error{ InvalidPath, OutOfMemory };
/// `InitError`, an endpoint that is not among the paths, a zero count, or
/// counts that merge past `usize`.
pub const FromEdgesError = error{ InvalidPath, UnknownPath, InvalidCount, CountOverflow, OutOfMemory };
/// What aggregating a graph into directories fails with.
pub const AggregateError = error{ InvalidPath, CountOverflow, OutOfMemory };
pub fn init(gpa: std.mem.Allocator, paths: []const []const u8) InitError!*Storage {
    return initTracked(gpa, paths, null);
}
pub fn initTracked(gpa: std.mem.Allocator, paths: []const []const u8, progress: ?*diagnostic_module.Progress) InitError!*Storage {
    const g = try gpa.create(Storage);
    g.* = .{ .allocator = gpa, .arena = .init(gpa) };
    errdefer g.deinit();
    const a = g.arena.allocator();
    var list: std.ArrayList([]const u8) = .empty;
    for (paths) |raw| {
        if (progress) |current| current.at(.paths, raw);
        const path = try path_module.normalize(a, raw);
        if (path.len == 0) return error.InvalidPath;
        const entry = try g.files.getOrPut(a, path);
        if (!entry.found_existing) try list.append(a, path);
    }
    if (progress) |current| current.at(.paths, null);
    std.mem.sort([]const u8, list.items, {}, t.stringsLess);
    g.paths = try list.toOwnedSlice(a);
    std.debug.assert(g.paths.len == g.files.count());
    return g;
}
pub const ScannedToken = struct { kind: t.Token.Kind, text: []const u8 };
/// Whether the scan recorded every token `rule` names.
pub fn scannedFor(g: *const Storage, rule: check_module.TokenRule) bool {
    for (rule.tokens) |token| {
        for (g.scanned_tokens) |scanned| {
            if (scanned.kind == rule.kind and std.mem.eql(u8, scanned.text, token)) break;
        } else return false;
    }
    return true;
}
pub fn deinit(g: *Storage) void {
    const gpa = g.allocator;
    g.arena.deinit();
    defer gpa.destroy(g);
    g.* = undefined;
}
/// Build a graph from caller edges. Endpoints must be among paths.
pub fn fromEdges(gpa: std.mem.Allocator, paths: []const []const u8, edges: []const t.Edge) FromEdgesError!*Storage {
    const g = try init(gpa, paths);
    errdefer g.deinit();
    const a = g.arena.allocator();
    const owned = try a.alloc(t.Edge, edges.len);
    for (edges, owned) |edge, *dest| {
        if (edge.count == 0) return error.InvalidCount;
        const from = try path_module.normalize(a, edge.from);
        const to = try path_module.normalize(a, edge.to);
        if (!g.files.contains(from) or !g.files.contains(to)) return error.UnknownPath;
        dest.* = .{ .from = from, .to = to, .kind = edge.kind, .count = edge.count };
    }
    g.edges = try coalesce(owned);
    for (g.edges) |edge| {
        std.debug.assert(edge.count > 0);
        std.debug.assert(g.files.contains(edge.from));
        std.debug.assert(g.files.contains(edge.to));
    }
    return g;
}
/// Directory nodes at depth (0 is the root, 1 the first component).
/// The returned graph is independent of this one, with no manifest references.
/// Unsupported imports retain their original source paths and byte offsets.
/// Directory self edges are retained: they describe coupling within a directory.
pub fn aggregate(g: *const Storage, gpa: std.mem.Allocator, depth: usize) AggregateError!*Storage {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const paths = try a.alloc([]const u8, g.paths.len);
    for (g.paths, paths) |path, *dest| dest.* = path_module.directory(path, depth);
    const edges = try a.alloc(t.Edge, g.edges.len);
    for (g.edges, edges) |edge, *dest| dest.* = .{ .from = path_module.directory(edge.from, depth), .to = path_module.directory(edge.to, depth), .kind = edge.kind, .count = edge.count };
    // '.' is a graph node for the root, not a file path.
    const result = try Storage.init(gpa, &.{});
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
    const unsupported = try ra.alloc(t.UnsupportedReference, g.unsupported.len);
    for (g.unsupported, unsupported) |record, *dest| {
        dest.* = record;
        if (record.from) |from| dest.from = try ra.dupe(u8, from);
    }
    result.unsupported = unsupported;
    result.edges = try coalesce(copied);
    return result;
}
/// Analysis owns its results independently of the graph.
pub fn coalesce(edges: []t.Edge) error{CountOverflow}![]const t.Edge {
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

/// An edge between positions in sorted `paths`, before it is coalesced.
pub const Pending = struct { from: u32, to: u32, kind: t.Kind };
/// Each path's position, for `Pending` edges. Paths are sorted, so position
/// order is the path order `edgesLess` sorts by.
pub fn positions(arena: std.mem.Allocator, paths: []const []const u8) std.mem.Allocator.Error!std.StringHashMapUnmanaged(u32) {
    if (paths.len > std.math.maxInt(u32)) return error.OutOfMemory;
    var result: std.StringHashMapUnmanaged(u32) = .empty;
    try result.ensureTotalCapacity(arena, @intCast(paths.len));
    for (paths, 0..) |path, i| {
        if (i > 0) std.debug.assert(t.stringsLess({}, paths[i - 1], path));
        result.putAssumeCapacity(path, @intCast(i));
        std.debug.assert(result.get(path).? == i);
    }
    return result;
}
/// `coalesce` for pending edges, into exactly the storage the result needs.
pub fn coalescePending(arena: std.mem.Allocator, paths: []const []const u8, pending: []Pending) std.mem.Allocator.Error![]const t.Edge {
    for (pending) |edge| {
        std.debug.assert(edge.from < paths.len);
        std.debug.assert(edge.to < paths.len);
    }
    std.mem.sort(Pending, pending, {}, struct {
        fn less(_: void, x: Pending, y: Pending) bool {
            if (x.from != y.from) return x.from < y.from;
            if (x.to != y.to) return x.to < y.to;
            return @backingInt(x.kind) < @backingInt(y.kind);
        }
    }.less);
    var n: usize = 0;
    for (pending, 0..) |edge, i| {
        if (i == 0 or !std.meta.eql(edge, pending[i - 1])) n += 1;
    }
    const edges = try arena.alloc(t.Edge, n);
    n = 0;
    for (pending, 0..) |edge, i| {
        if (i > 0 and std.meta.eql(edge, pending[i - 1])) {
            edges[n - 1].count += 1;
        } else {
            edges[n] = .{ .from = paths[edge.from], .to = paths[edge.to], .kind = edge.kind };
            n += 1;
        }
    }
    std.debug.assert(n == edges.len);
    for (edges) |edge| std.debug.assert(edge.count > 0);
    return edges;
}

pub fn owner(comptime Owner: type, state: *Storage) Owner {
    return @fromBackingInt(@intCast(@intFromPtr(state))); // safe: the owning handle preserves the allocated state's address.
}
pub fn get(g: anytype) *Storage {
    return @ptrFromInt(@backingInt(g));
}

comptime {
    std.debug.assert(@sizeOf(Pending) == 12);
    std.debug.assert(@bitSizeOf(@FieldType(Pending, "from")) == 32);
    std.debug.assert(@bitSizeOf(@FieldType(Pending, "to")) == 32);
}
