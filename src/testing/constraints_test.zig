const build_module = @import("../lang/go/build.zig");
const build = build_module;
const std = @import("std");
const g = @import("../gantry.zig");
const f = @import("support.zig");
const a = std.testing.allocator;
const fixture: f.Fixture = .{ .items = &.{
    .{ .path = "go.mod", .text = "module example.org/app" },
    .{ .path = "main.go", .text = "package main\nimport \"example.org/app/lib\"" },
    .{ .path = "lib/a_linux_amd64.go", .text = "//go:build linux && (amd64 || arm64) && !custom\n\npackage lib\nimport \"example.org/app/dep\"" },
    .{ .path = "lib/a_windows.go", .text = "package lib\nimport \"example.org/app/dep\"" },
    .{ .path = "lib/b.go", .text = "//go:build custom || (darwin && arm64)\n\npackage lib\nimport \"example.org/app/dep\"" },
    .{ .path = "lib/c_test.go", .text = "package lib_test\nimport \"example.org/app/dep\"" },
    .{ .path = "dep/a.go", .text = "package dep" },
} };

test "Go records constraints and test package identity without choosing a host" {
    var graph = try fixture.scan(a, .{});
    defer graph.deinit();
    try std.testing.expectEqual(6, graph.goFiles().len);
    try std.testing.expectEqualStrings("lib_test", graph.goFiles()[4].package);
    try std.testing.expectEqualStrings("linux && (amd64 || arm64) && !custom", graph.goFiles()[1].constraint.?);
    try std.testing.expectEqualStrings("linux", graph.goFiles()[1].os.?);
    try std.testing.expectEqualStrings("amd64", graph.goFiles()[1].arch.?);
    try std.testing.expect(graph.goFiles()[3].selected);
    try f.edge(&graph, "main.go", "lib/a_windows.go", .import, 1);
}

test "Go caller target filters both importers and package expansion" {
    var graph = try fixture.scan(a, .{ .go_target = .{ .os = "linux", .arch = "amd64" }, .kinds = &.{.import} });
    defer graph.deinit();
    try std.testing.expectEqual(2, graph.edges().len);
    try f.edge(&graph, "main.go", "lib/a_linux_amd64.go", .import, 1);
    try f.edge(&graph, "lib/a_linux_amd64.go", "dep/a.go", .import, 1);
    var custom = try fixture.scan(a, .{ .go_target = .{ .os = "windows", .arch = "arm64", .tags = &.{"custom"} } });
    defer custom.deinit();
    try f.edge(&custom, "main.go", "lib/b.go", .import, 1);
    try std.testing.expect(!custom.goFiles()[1].selected);
}

test "Go build expression rejects malformed syntax and honors OS aliases" {
    try std.testing.expect(try build.evaluate(a, "unix && linux && !windows", .{ .os = "android", .arch = "arm64" }));
    for ([_][]const u8{ "a &&", "(a", "a b", "a | b", "a)", "" }) |expression| try std.testing.expectError(error.InvalidBuildConstraint, build.evaluate(a, expression, .{ .os = "linux", .arch = "amd64" }));
}

test "Go constraints and imports share one source read" {
    const Reader = struct {
        const Self = @This();
        calls: usize = 0,
        fn read(scratch: std.mem.Allocator, self: *Self, name: []const u8) !?[]const u8 {
            self.calls += 1;
            const value = try scratch.dupe(u8, if (std.mem.eql(u8, name, "go.mod")) "module example.org/app" else if (std.mem.eql(u8, name, "main.go")) "//go:build linux\n\npackage app\nimport \"example.org/app/lib\"" else "package lib");
            return value;
        }
    };
    var reader: Reader = .{};
    var graph = try g.scan(a, &.{ "go.mod", "main.go", "lib/a.go" }, &reader, Reader.read, .{ .manifests = false, .go_target = .{ .os = "linux", .arch = "amd64" } });
    defer graph.deinit();
    try f.edge(&graph, "main.go", "lib/a.go", .import, 1);
    try std.testing.expectEqualStrings("app", graph.goFiles()[1].package);
    try std.testing.expectEqualStrings("linux", graph.goFiles()[1].constraint.?);
    try std.testing.expectEqual(3, reader.calls);
}
