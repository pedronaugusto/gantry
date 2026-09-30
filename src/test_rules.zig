const std = @import("std");
const g = @import("gantry.zig");
const f = @import("test_support.zig");
const a = std.testing.allocator;
const eq = std.testing.expectEqual;
const expect = std.testing.expect;
test "path globs are component-aware and double-star covers zero directories" {
    const cases = [_]struct { pattern: []const u8, path: []const u8, want: bool }{
        .{ .pattern = "src/**/*.zig", .path = "src/main.zig", .want = true },
        .{ .pattern = "src/**/*.zig", .path = "src/deep/main.zig", .want = true },
        .{ .pattern = "src/*.zig", .path = "src/deep/main.zig", .want = false },
        .{ .pattern = "**/main.zig", .path = "main.zig", .want = true },
        .{ .pattern = "**/a/**/b", .path = "x/a/z/a/b", .want = true },
        .{ .pattern = "**/a/**/b", .path = "x/a/z/a/c", .want = false },
        .{ .pattern = "a?c*", .path = "dir/abcde", .want = true },
        .{ .pattern = "src/*", .path = "src/deep/x", .want = false },
        .{ .pattern = "src/**", .path = "src", .want = true },
        .{ .pattern = "src/**", .path = "src2/x", .want = false },
        .{ .pattern = "**", .path = "", .want = true },
        .{ .pattern = "*.zig", .path = "main.ZIG", .want = false },
        .{ .pattern = "a*b?d", .path = "a12b3d", .want = true },
    };
    for (cases) |case| try eq(case.want, g.rules.matches(case.pattern, case.path));
}
test "fixture: layers entry exceptions required modules and no cycles are data" {
    var graph = try g.Graph.fromEdges(a, &.{ "daemon/leaf.zig", "daemon/station.zig", "daemon/main.zig", "daemon/tests.zig", "daemon/a.zig", "daemon/b.zig" }, &.{
        .{ .from = "daemon/leaf.zig", .to = "daemon/station.zig" },
        .{ .from = "daemon/station.zig", .to = "daemon/main.zig" },
        .{ .from = "daemon/tests.zig", .to = "daemon/main.zig" },
        .{ .from = "daemon/a.zig", .to = "daemon/b.zig" },
        .{ .from = "daemon/b.zig", .to = "daemon/a.zig" },
    });
    defer graph.deinit();
    const findings = try graph.check(a, .{
        .ordered = &.{.{ .name = "layers", .layers = &.{
            .{ .name = "leaves", .patterns = &.{} }, .{ .name = "station", .patterns = &.{"daemon/station.zig"} }, .{ .name = "entry", .patterns = &.{"daemon/main.zig"} }, .{ .name = "tests", .patterns = &.{"daemon/tests.zig"} },
        } }},
        .nothing_imports = &.{.{ .name = "entry", .to = "**/main.zig" }},
        .allowed = &.{.{ .rule = "entry", .from = "daemon/tests.zig", .to = "daemon/main.zig" }},
        .required = &.{.{ .name = "named modules", .paths = &.{ "daemon/station.zig", "daemon/missing.zig" } }},
        .no_cycles = "acyclic",
    });
    defer a.free(findings);
    try eq(5, findings.len);
    try eq(.upward, findings[0].reason);
    try eq(.upward, findings[1].reason);
    try eq(.entry, findings[2].reason);
    try eq(.missing, findings[3].reason);
    try eq(.cycle, findings[4].reason);
    try std.testing.expectEqualStrings("daemon/station.zig", findings[2].edge.?.from);
}
test "every matching edge restriction reports and allowances waive only their named rule" {
    var graph = try g.Graph.fromEdges(a, &.{ "a", "b" }, &.{ .{ .from = "a", .to = "b" }, .{ .from = "a", .to = "b", .kind = .asset } });
    defer graph.deinit();
    const findings = try graph.check(a, .{
        .forbidden = &.{ .{ .name = "first" }, .{ .name = "second", .kind = .import } },
        .allowed = &.{.{ .rule = "first", .from = "a", .to = "b" }},
    });
    defer a.free(findings);
    try eq(1, findings.len);
    try std.testing.expectEqualStrings("second", findings[0].rule);
    try eq(g.Kind.import, findings[0].edge.?.kind);
}
test "fixture: proto packages confined packages and forbidden member access" {
    var graph = try (f.Fixture{ .items = &.{
        .{ .path = "proto/root.zig", .text = "const s = @import(\"std\"); const l = @import(\"strand\"); const x = @import(\"lookout\"); const y = @import(\"../daemon/main.zig\");" },
        .{ .path = "daemon/main.zig", .text = "const p = @import(\"proto\"); const m = p\n.mirror; const m2 = @import(\"proto\").mirror; const l = @import(\"lookout\");" },
        .{ .path = "daemon/filewatch.zig", .text = "const l = @import(\"lookout\");" },
    } }).scan(a, .{ .named_modules = &.{.{ .name = "proto", .path = "proto/root.zig" }} });
    defer graph.deinit();
    const findings = try graph.check(a, .{
        .forbidden = &.{.{ .name = "proto siblings", .from = "proto/**", .to = "**" }},
        .allowed = &.{.{ .rule = "proto siblings", .from = "proto/**", .to = "proto/*" }},
        .references = &.{
            .{ .name = "proto packages", .from = "proto/**", .unresolved_only = true, .except_targets = &.{ "std", "strand" } },
            .{ .name = "watcher owner", .target = "lookout", .except_from = &.{"daemon/filewatch.zig"} },
            .{ .name = "client mirror", .from = "daemon/**", .target = "proto", .member = "mirror" },
        },
    });
    defer a.free(findings);
    try eq(6, findings.len);
    var members: usize = 0;
    for (findings) |v| if (std.mem.eql(u8, v.rule, "client mirror")) {
        members += 1;
        try expect(v.reference.?.member != null);
    };
    try eq(2, members);
}
test "first matching layer wins and unspecified paths default to zero" {
    var graph = try g.Graph.fromEdges(a, &.{ "leaf", "high" }, &.{ .{ .from = "leaf", .to = "high" }, .{ .from = "high", .to = "leaf" } });
    defer graph.deinit();
    const findings = try graph.check(a, .{ .ordered = &.{.{ .name = "layers", .layers = &.{ .{ .name = "empty", .patterns = &.{} }, .{ .name = "high", .patterns = &.{"high"} }, .{ .name = "fallback", .patterns = &.{"**"} } } }} });
    defer a.free(findings);
    try eq(1, findings.len);
    try std.testing.expectEqualStrings("high", findings[0].edge.?.from);
}
