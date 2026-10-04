const std = @import("std");
const g = @import("gantry.zig");
const f = @import("testing/test_support.zig");
const a = std.testing.allocator;

test "Go local replacements are scoped and workspace overrides win" {
    var graph = try (f.Fixture{ .items = &.{
        .{ .path = "go.work", .text = "use (\n ./app\n ./shared\n)\nreplace example.org/dep => ./override\n" },
        .{ .path = "app/go.mod", .text = "module example.org/app\nrequire example.org/dep v1.0.0\nreplace (\n example.org/dep v1.0.0 => ../dep\n example.org/out => ../../outside\n)" },
        .{ .path = "app/a.go", .text = "import (\"example.org/shared/pkg\"; \"example.org/dep/pkg\"; \"example.org/out/pkg\")" },
        .{ .path = "shared/go.mod", .text = "module example.org/shared" },
        .{ .path = "shared/pkg/a.go" },
        .{ .path = "dep/go.mod", .text = "module fork.org/dep" },
        .{ .path = "dep/pkg/a.go" },
        .{ .path = "override/go.mod", .text = "module fork.org/override" },
        .{ .path = "override/pkg/a.go" },
        .{ .path = "other/go.mod", .text = "module example.org/other" },
        .{ .path = "other/a.go", .text = "import \"example.org/shared/pkg\"" },
    } }).scan(a, .{ .manifests = false });
    defer graph.deinit();
    try f.edge(&graph, "app/a.go", "shared/pkg/a.go", .import, 1);
    try f.edge(&graph, "app/a.go", "override/pkg/a.go", .import, 1);
    try std.testing.expectEqual(2, graph.edges().len);
}

test "Go replacement routes module aliases and versions inside the repository" {
    var graph = try (f.Fixture{ .items = &.{
        .{ .path = "go.mod", .text = "module example.org/main\nrequire example.org/lib v1.2.0\nreplace example.org/lib v1.1.0 => ./wrong\nreplace example.org/lib v1.2.0 => \"./local lib\" // local\n" },
        .{ .path = "a.go", .text = "import \"example.org/lib/pkg\"" },
        .{ .path = "local lib/go.mod", .text = "module fork.org/lib" },
        .{ .path = "local lib/pkg/a.go" },
        .{ .path = "wrong/pkg/a.go" },
    } }).scan(a, .{});
    defer graph.deinit();
    try f.edge(&graph, "a.go", "local lib/pkg/a.go", .import, 1);
    try std.testing.expectEqual(1, graph.edges().len);
}

test "Go exact replacement precedes wildcard and workspace members cannot be replaced" {
    const config = @import("go_config.zig");
    const replacements = &[_]config.Replacement{
        .{ .name = "lib", .version = "v1.0.0", .root = "exact" },
        .{ .name = "lib", .version = "", .root = "wildcard" },
    };
    try std.testing.expectEqualStrings("exact", config.replacement(replacements, "lib", "v1.0.0").?.root.?);
    var graph = try (f.Fixture{ .items = &.{
        .{ .path = "go.work", .text = "use (\n ./app\n ./shared\n)\nreplace example.org/shared => ./override" },
        .{ .path = "app/go.mod", .text = "module example.org/app\nrequire example.org/shared v1.0.0" },
        .{ .path = "app/a.go", .text = "import \"example.org/shared/pkg\"" },
        .{ .path = "shared/go.mod", .text = "module example.org/shared" },
        .{ .path = "shared/pkg/a.go" },
        .{ .path = "override/go.mod", .text = "module example.org/override" },
        .{ .path = "override/pkg/a.go" },
    } }).scan(a, .{});
    defer graph.deinit();
    try f.edge(&graph, "app/a.go", "shared/pkg/a.go", .import, 1);
}
