const std = @import("std");
const g = @import("gantry.zig");
const f = @import("test_support.zig");
const a = std.testing.allocator;

test "test imports remain edges with kind and rules can exempt them" {
    const fixture: f.Fixture = .{ .items = &.{
        .{ .path = "go.mod", .text = "module example.org/app" },
        .{ .path = "main.go", .text = "package app\nimport \"example.org/app/lib\"" },
        .{ .path = "main_test.go", .text = "package app_test\nimport \"example.org/app/lib\"" },
        .{ .path = "lib/a.go", .text = "package lib" },
        .{ .path = "lib/a_test.go", .text = "package lib_test" },
        .{ .path = "tests/test_app.py", .text = "import util" },
        .{ .path = "util.py" },
        .{ .path = "app.spec.ts", .text = "import './util';" },
        .{ .path = "util.ts" },
        .{ .path = "testimony.ts", .text = "import './util';" },
    } };
    var graph = try fixture.scan(a, .{});
    defer graph.deinit();
    try f.edge(&graph, "main_test.go", "lib/a.go", .@"test", 1);
    try f.edge(&graph, "main.go", "lib/a_test.go", .@"test", 1);
    try f.edge(&graph, "tests/test_app.py", "util.py", .@"test", 1);
    try f.edge(&graph, "app.spec.ts", "util.ts", .@"test", 1);
    try f.edge(&graph, "testimony.ts", "util.ts", .import, 1);
    const findings = try graph.check(a, .{
        .forbidden = &.{.{ .name = "imports" }},
        .allowed = &.{.{ .rule = "imports", .kind = .@"test" }},
    });
    defer a.free(findings);
    try std.testing.expectEqual(2, findings.len);
    var production = try fixture.scan(a, .{ .kinds = &.{.import} });
    defer production.deinit();
    try std.testing.expectEqual(2, production.edges.len);
}

test "Rust cfg test items inline modules and file modules propagate test kind" {
    var graph = try (f.Fixture{ .items = &.{
        .{ .path = "src/lib.rs", .text = "mod util; #[cfg(test)] mod fixture; mod tests; mod production { use crate::util; } #[cfg(test)] fn check() { use crate::fixture; }" },
        .{ .path = "src/util.rs", .text = "#[cfg(test)] mod tests { use super::Thing; use crate::fixture; } use crate::fixture;" },
        .{ .path = "src/fixture.rs", .text = "mod child; use crate::util;" },
        .{ .path = "src/fixture/child.rs", .text = "use crate::util;" },
        .{ .path = "src/tests.rs", .text = "use crate::util;" },
    } }).scan(a, .{});
    defer graph.deinit();
    try f.edge(&graph, "src/lib.rs", "src/util.rs", .import, 2);
    try f.edge(&graph, "src/lib.rs", "src/fixture.rs", .@"test", 2);
    try f.edge(&graph, "src/lib.rs", "src/tests.rs", .@"test", 1);
    try f.edge(&graph, "src/fixture.rs", "src/fixture/child.rs", .@"test", 1);
    try f.edge(&graph, "src/fixture/child.rs", "src/util.rs", .@"test", 1);
    try f.edge(&graph, "src/util.rs", "src/fixture.rs", .@"test", 2);
}

test "Rust inner cfg test marks the file including incoming edges" {
    var graph = try (f.Fixture{ .items = &.{
        .{ .path = "src/lib.rs", .text = "mod helper;" },
        .{ .path = "src/helper.rs", .text = "#![cfg(test)]\nuse crate::util;" },
        .{ .path = "src/util.rs" },
    } }).scan(a, .{});
    defer graph.deinit();
    try f.edge(&graph, "src/lib.rs", "src/helper.rs", .@"test", 1);
    try f.edge(&graph, "src/helper.rs", "src/util.rs", .@"test", 1);
}
