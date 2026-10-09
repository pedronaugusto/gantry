const std = @import("std");
const g = @import("gantry.zig");
const f = @import("testing/support.zig");
const a = std.testing.allocator;
const eq = std.testing.expectEqual;
const expect = std.testing.expect;
test "checked analysis rejects unknown source paths" {
    try std.testing.expectError(error.UnknownPath, g.Analysis.init(a, &.{"a"}, &.{.{ .from = "missing", .to = "a" }}));
}
test "checked analysis rejects unknown target paths" {
    try std.testing.expectError(error.UnknownPath, g.Analysis.init(a, &.{"a"}, &.{.{ .from = "a", .to = "missing" }}));
}
test "checked analysis rejects invalid paths and counts" {
    try std.testing.expectError(error.InvalidPath, g.Analysis.init(a, &.{"../a"}, &.{}));
    try std.testing.expectError(error.InvalidPath, g.Analysis.init(a, &.{"."}, &.{}));
    try std.testing.expectError(error.InvalidPath, g.Analysis.init(a, &.{"a"}, &.{.{ .from = "a", .to = "/a" }}));
    try std.testing.expectError(error.InvalidCount, g.Analysis.init(a, &.{"a"}, &.{.{ .from = "a", .to = "a", .count = .fromRaw(0) }}));
    try std.testing.expectError(error.CountOverflow, g.Analysis.init(a, &.{"a"}, &.{ .{ .from = "a", .to = "a", .count = .fromRaw(std.math.maxInt(usize)) }, .{ .from = "a", .to = "a" } }));
}
test "checked analysis uses graph normalization and deterministic ordering" {
    const paths = &[_][]const u8{ "c", "b", "./a", "a" };
    const edges = &[_]g.Edge{
        .{ .from = "c", .to = "a" },
        .{ .from = "a", .to = "c" },
        .{ .from = "b", .to = "a" },
        .{ .from = "a", .to = "b" },
        .{ .from = "a", .to = "b" },
    };
    var graph = try g.Graph.fromEdges(a, paths, edges);
    var expected = try graph.analyze(a);
    defer expected.deinit();
    graph.deinit();
    var actual = try g.Analysis.init(a, paths, edges);
    defer actual.deinit();
    try std.testing.expectEqualDeep(expected.layers(), actual.layers());
    try std.testing.expectEqualDeep(expected.components(), actual.components());
    try std.testing.expectEqualDeep(expected.cycles(), actual.cycles());
    var normalized = try g.Analysis.init(a, &.{ "./b", "x/../a" }, &.{ .{ .from = "./a", .to = "x/../b" }, .{ .from = "b", .to = "a" } });
    defer normalized.deinit();
    try std.testing.expectEqualDeep(&[_][]const u8{ "a", "b", "a" }, normalized.cycles()[0].path);
}

fn checkedAnalysisAllocations(alloc: std.mem.Allocator) !void {
    var analysis = try g.Analysis.init(alloc, &.{ "./b", "a", "c", "a" }, &.{
        .{ .from = "a", .to = "b" }, .{ .from = "./b", .to = "a" }, .{ .from = "b", .to = "c" },
    });
    defer analysis.deinit();
    try eq(3, analysis.layers().len);
    try eq(1, analysis.cycles().len);
    try eq(1, analysis.layers()[2].depth);
}
test "checked analysis releases every failed allocation" {
    try f.checkAllAllocationFailures(checkedAnalysisAllocations, .{});
}

test "longest path depths include shortcuts disconnected nodes and collapsed SCCs" {
    var graph = try g.Graph.fromEdges(a, &.{ "a", "b", "c", "d", "e", "isolated" }, &.{
        .{ .from = "a", .to = "b" }, .{ .from = "b", .to = "c" }, .{ .from = "c", .to = "d" }, .{ .from = "a", .to = "d" }, .{ .from = "d", .to = "e" }, .{ .from = "e", .to = "d" },
    });
    defer graph.deinit();
    var analysis = try graph.analyze(a);
    defer analysis.deinit();
    const depths = [_]usize{ 0, 1, 2, 3, 3, 0 };
    for (analysis.layers(), depths) |layer, depth| try eq(depth, layer.depth);
    try eq(1, analysis.cycles().len);
    try eq(2, analysis.cycles()[0].members.len);
    try std.testing.expectEqualStrings("d", analysis.cycles()[0].path[0]);
    try std.testing.expectEqualStrings("d", analysis.cycles()[0].path[2]);
}
test "SCCs find cycles longer than mutual pairs and self imports" {
    var graph = try g.Graph.fromEdges(a, &.{ "a", "b", "c", "d", "e" }, &.{ .{ .from = "a", .to = "b" }, .{ .from = "b", .to = "c" }, .{ .from = "c", .to = "a" }, .{ .from = "d", .to = "d" } });
    defer graph.deinit();
    var analysis = try graph.analyze(a);
    defer analysis.deinit();
    try eq(2, analysis.cycles().len);
    try eq(3, analysis.cycles()[0].members.len);
    try eq(4, analysis.cycles()[0].path.len);
    try eq(2, analysis.cycles()[1].path.len);
    for (analysis.cycles()) |cycle| {
        for (cycle.path[0 .. cycle.path.len - 1], cycle.path[1..]) |from, to| try f.edge(&graph, from, to, .import, 1);
    }
}
test "cycle witnesses use edges rather than sorting the members into a fake loop" {
    var graph = try g.Graph.fromEdges(a, &.{ "a", "b", "c", "d" }, &.{ .{ .from = "a", .to = "c" }, .{ .from = "c", .to = "b" }, .{ .from = "b", .to = "d" }, .{ .from = "d", .to = "a" } });
    defer graph.deinit();
    var analysis = try graph.analyze(a);
    defer analysis.deinit();
    const want = &[_][]const u8{ "a", "c", "b", "d", "a" };
    for (want, analysis.cycles()[0].path) |w, path| try std.testing.expectEqualStrings(w, path);
}
test "deep graphs use heap stacks in SCC and layer analysis" {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    const n = 20_000;
    const paths = try alloc.alloc([]const u8, n);
    for (paths, 0..) |*path, i| path.* = try alloc.print("{d:0>5}", .{i});
    const edges = try alloc.alloc(g.Edge, n - 1);
    for (edges, 0..) |*edge, i| edge.* = .{ .from = paths[i], .to = paths[i + 1] };
    var graph = try g.Graph.fromEdges(a, paths, edges);
    defer graph.deinit();
    var analysis = try graph.analyze(a);
    defer analysis.deinit();
    try eq(n - 1, analysis.layers()[n - 1].depth);
    try eq(0, analysis.cycles().len);
}
test "every node in a rootless cycle shares depth zero" {
    var graph = try g.Graph.fromEdges(a, &.{ "a", "b" }, &.{ .{ .from = "a", .to = "b" }, .{ .from = "b", .to = "a" } });
    defer graph.deinit();
    var analysis = try graph.analyze(a);
    defer analysis.deinit();
    for (analysis.layers()) |layer| try eq(0, layer.depth);
}
test "file edge occurrence counts keep kinds separate and reject overflow" {
    var graph = try g.Graph.fromEdges(a, &.{ "a", "b" }, &.{ .{ .from = "a", .to = "b" }, .{ .from = "a", .to = "b", .count = .fromRaw(2) }, .{ .from = "a", .to = "b", .kind = .link }, .{ .from = "a", .to = "b", .kind = .asset } });
    defer graph.deinit();
    try eq(3, graph.edges().len);
    try f.edge(&graph, "a", "b", .import, 3);
    try std.testing.expectError(error.InvalidCount, g.Graph.fromEdges(a, &.{ "a", "b" }, &.{.{ .from = "a", .to = "b", .count = .fromRaw(0) }}));
    try std.testing.expectError(error.UnknownPath, g.Graph.fromEdges(a, &.{"a"}, &.{.{ .from = "a", .to = "missing" }}));
    try std.testing.expectError(error.CountOverflow, g.Graph.fromEdges(a, &.{ "a", "b" }, &.{ .{ .from = "a", .to = "b", .count = .fromRaw(std.math.maxInt(usize)) }, .{ .from = "a", .to = "b" } }));
}
test "aggregation at every depth counts isolated directories and root files" {
    var graph = try g.Graph.fromEdges(a, &.{ "main.zig", "src/a/x.zig", "src/b/y.zig", "alone/z.zig" }, &.{ .{ .from = "main.zig", .to = "src/a/x.zig" }, .{ .from = "src/a/x.zig", .to = "src/b/y.zig", .count = .fromRaw(2) } });
    defer graph.deinit();
    var root = try graph.aggregate(a, 0);
    defer root.deinit();
    try eq(1, root.paths().len);
    try f.edge(&root, ".", ".", .import, 3);
    var root_analysis = try root.analyze(a);
    defer root_analysis.deinit();
    try std.testing.expectEqualDeep(&[_][]const u8{ ".", "." }, root_analysis.cycles()[0].path);
    var one = try graph.aggregate(a, 1);
    defer one.deinit();
    try eq(3, one.paths().len);
    try f.edge(&one, ".", "src", .import, 1);
    try f.edge(&one, "src", "src", .import, 2);
    var two = try graph.aggregate(a, 2);
    defer two.deinit();
    try eq(4, two.paths().len);
    try f.edge(&two, "src/a", "src/b", .import, 2);
}
test "results are deterministic when path and edge input order changes" {
    const paths = &[_][]const u8{ "c", "b", "a" };
    const edges = &[_]g.Edge{ .{ .from = "c", .to = "a" }, .{ .from = "a", .to = "b" }, .{ .from = "b", .to = "c" }, .{ .from = "a", .to = "b" } };
    var x = try g.Graph.fromEdges(a, paths, edges);
    defer x.deinit();
    var y = try g.Graph.fromEdges(a, &.{ "a", "b", "c" }, &.{ edges[3], edges[2], edges[1], edges[0] });
    defer y.deinit();
    try std.testing.expectEqualDeep(x.edges(), y.edges());
    var ax = try x.analyze(a);
    defer ax.deinit();
    var ay = try y.analyze(a);
    defer ay.deinit();
    try std.testing.expectEqualDeep(ax.layers(), ay.layers());
    try std.testing.expectEqualDeep(ax.cycles(), ay.cycles());
    try std.testing.expectEqualDeep(ax.components(), ay.components());
}
test "analysis and aggregate own their strings after original graph deinit" {
    var graph = try g.Graph.fromEdges(a, &.{ "src/a.zig", "lib/b.zig" }, &.{.{ .from = "src/a.zig", .to = "lib/b.zig" }});
    var analysis = try graph.analyze(a);
    defer analysis.deinit();
    var aggregate = try graph.aggregate(a, 1);
    defer aggregate.deinit();
    graph.deinit();
    try std.testing.expectEqualStrings("lib/b.zig", analysis.layers()[0].path);
    try f.edge(&aggregate, "src", "lib", .import, 1);
}
fn allocationScenario(alloc: std.mem.Allocator) !void {
    var graph = try (f.Fixture{ .items = &.{
        .{ .path = "src/a.zig", .text = "const b = @import(\"b.zig\"); const p = @import(\"proto\"); const m = p.mirror;" },
        .{ .path = "src/b.zig", .text = "const a = @import(\"a.zig\");" },
        .{ .path = "package.json", .text = "{\"dependencies\":{\"x\":\"1\"}}" },
        .{ .path = "tsconfig.json", .text = "{\"extends\": \"./base.json\"}" },
        .{ .path = "base.json", .text = "{\"compilerOptions\": {\"baseUrl\": \".\", \"paths\": {\"alias\": [\"dep\"]}}}" },
        .{ .path = "app.ts", .text = "import 'alias';" },
        .{ .path = "dep.d.ts" },
        .{ .path = "go.mod", .text = "module example.org/app\nreplace example.org/dep => ./local" },
        .{ .path = "app_linux.go", .text = "//go:build linux && !custom\n\npackage app\nimport \"example.org/dep\"" },
        .{ .path = "local/dep.go", .text = "package dep" },
        .{ .path = "src/lib.rs", .text = "#[cfg(test)] mod helper;" },
        .{ .path = "src/helper.rs", .text = "use crate::util;" },
        .{ .path = "src/util.rs" },
        .{ .path = "pkg/__init__.py", .text = "from .api import *" },
        .{ .path = "pkg/api.py", .text = "from .impl import Public\n__all__ = ['Public']" },
        .{ .path = "pkg/impl.py" },
        .{ .path = "notes/a.md", .text = "[[b]]" },
        .{ .path = "notes/b.md", .text = "notes/a.md" },
    } }).scan(alloc, .{ .kinds = &.{ .import, .@"test", .link, .asset }, .go_target = .{ .os = "linux", .arch = "amd64" } });
    defer graph.deinit();
    var analysis = try graph.analyze(alloc);
    defer analysis.deinit();
    var dirs = try graph.aggregate(alloc, 1);
    defer dirs.deinit();
    var findings_owned = try graph.check(alloc, .{ .forbidden = &.{.{ .name = "all" }}, .references = &.{.{ .name = "relative", .relative = true, .suffix = ".zig" }}, .no_cycles = "cycles" });
    defer findings_owned.deinit();
    const findings = findings_owned.items();
    try expect(findings.len > 0);
}
test "every allocation failure releases scan graph analysis aggregation and findings" {
    try f.checkAllAllocationFailures(allocationScenario, .{});
}

test "managed results expose no writable Graph storage or ownership" {
    try expect(@typeInfo(g.Graph) != .@"struct");
}

test "managed results expose no writable Analysis storage or ownership" {
    try expect(@typeInfo(g.Analysis) != .@"struct");
}

test "managed results expose no writable Imports storage or ownership" {
    try expect(@typeInfo(g.Imports) != .@"struct");
}

test "managed results expose no writable Paths storage or ownership" {
    try expect(@typeInfo(g.Paths) != .@"struct");
}

test "managed results return deeply read only slices" {
    const S = struct {
        fn readonly(comptime T: type) bool {
            return switch (@typeInfo(T)) {
                .pointer => |p| p.attrs.@"const" and readonly(p.child),
                .@"struct" => |fields| blk: {
                    inline for (fields.field_types) |field| if (!readonly(field)) break :blk false;
                    break :blk true;
                },
                .optional => |o| readonly(o.child),
                else => true,
            };
        }
    };
    inline for (.{ g.Graph.paths, g.Graph.edges, g.Graph.dependencies, g.Graph.references, g.Graph.unread, g.Graph.goFiles, g.Analysis.layers, g.Analysis.cycles, g.Analysis.components, g.Imports.items, g.Paths.items }) |accessor| {
        try expect(S.readonly(@typeInfo(@TypeOf(accessor)).@"fn".return_type.?));
    }
}

test "graph membership preserves normalized nodes after moving the owner" {
    var graph = try g.Graph.init(a, &.{ "src/../a.zig", "./b.zig" });
    var moved = graph;
    graph = undefined;
    defer moved.deinit();
    try expect(moved.contains("a.zig"));
    try expect(moved.contains("b.zig"));
    try expect(!moved.contains("./a.zig"));
    try expect(!moved.contains("missing.zig"));
    var root = try moved.aggregate(a, 0);
    defer root.deinit();
    try expect(root.contains("."));
}

test "graph construction owns edge normalization" {
    try expect(!@hasDecl(g.Graph, "coalesce"));
    var edges = [_]g.Edge{
        .{ .from = "./b", .to = "a" },
        .{ .from = "a", .to = "./b", .count = .fromRaw(2) },
        .{ .from = "./a", .to = "b", .count = .fromRaw(3) },
    };
    const original = edges;
    var graph = try g.Graph.fromEdges(a, &.{ "b", "./a" }, &edges);
    defer graph.deinit();
    try std.testing.expectEqualDeep(original, edges);
    try std.testing.expectEqualDeep(&[_]g.Edge{
        .{ .from = "a", .to = "b", .count = .fromRaw(5) },
        .{ .from = "b", .to = "a" },
    }, graph.edges());
    edges[0].count = .fromRaw(99);
    try f.edge(&graph, "b", "a", .import, 1);
}

test "scan retains large recovered operands within a bounded allocator" {
    const storage = try a.alloc(u8, 256 * 1024);
    defer a.free(storage);
    var fixed: std.heap.FixedBufferAllocator = .init(storage);
    var graph = blk: {
        const name = try a.alloc(u8, 128 * 1024);
        defer a.free(name);
        @memset(name, 'x');
        const source = try std.mem.concat(a, u8, &.{ "package app\nimport \"", name, "\"" });
        defer a.free(source);
        // Memory readers may lend bytes. The graph must keep only its owned copy.
        const Reader = struct {
            const Self = @This();
            text: []const u8,
            fn read(reader: Self, _: std.mem.Allocator, _: std.Io, _: []const u8) !?[]const u8 {
                return reader.text;
            }
        };
        break :blk try g.scan(fixed.allocator(), std.testing.io, &.{"app.go"}, Reader{ .text = source }, Reader.read, .{});
    };
    defer graph.deinit();
    try eq(1, graph.references().len);
    try eq(128 * 1024, graph.references()[0].name.len);
    for (graph.references()[0].name) |byte| try eq(@as(u8, 'x'), byte);
    try expect(!graph.references()[0].resolved);
}
