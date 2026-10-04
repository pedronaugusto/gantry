const std = @import("std");
const g = @import("gantry.zig");
const f = @import("testing/test_support.zig");
const a = std.testing.allocator;
const eq = std.testing.expectEqual;
test "fixture: wiki relative links and assets fixtures" {
    var graph = try (f.Fixture{ .items = &.{
        .{ .path = "notes/well.md", .text = "the [[warden]] guards it; see [the map](../places/cistern.md)" },
        .{ .path = "notes/warden.md", .text = "back to [[well]]" },
        .{ .path = "places/cistern.md", .text = "# cistern" },
    } }).scan(a, .{ .kinds = &.{.link} });
    defer graph.deinit();
    var dirs = try graph.aggregate(a, 99);
    defer dirs.deinit();
    try eq(2, dirs.edges().len);
    try f.edge(&dirs, "notes", "notes", .link, 2);
    try f.edge(&dirs, "notes", "places", .link, 1);
    var analysis = try dirs.analyze(a);
    defer analysis.deinit();
    try eq(0, analysis.layers()[0].depth);
    try eq(1, analysis.layers()[1].depth);
    var assets = try (f.Fixture{ .items = &.{
        .{ .path = "site/index.html", .text = "<link href=\"css/main.css\"><img src=\"img/logo.svg\">" },
        .{ .path = "css/main.css", .text = "@import url(\"site/index.html\")" },
        .{ .path = "img/logo.svg", .text = "<svg/>" },
    } }).scan(a, .{ .kinds = &.{.asset} });
    defer assets.deinit();
    try eq(3, assets.edges().len);
    var cycles = try assets.analyze(a);
    defer cycles.deinit();
    try eq(1, cycles.cycles().len);
}
test "Markdown aliases headings escaped parentheses titles images and external URLs" {
    var graph = try (f.Fixture{ .items = &.{
        .{ .path = "notes/a.md", .text = "[[b#anchor|shown]] [b](b.md#x \"title\") ![img](../img/a.svg) [paren](../pages/a\\(b\\).md) [url](https://x/b.md) [mail](mailto:b.md) [self](#anchor) [[a]]" },
        .{ .path = "notes/b.md" },
        .{ .path = "img/a.svg" },
        .{ .path = "pages/a(b).md" },
    } }).scan(a, .{ .kinds = &.{.link} });
    defer graph.deinit();
    try eq(3, graph.edges().len);
    try f.edge(&graph, "notes/a.md", "notes/b.md", .link, 2);
    try f.edge(&graph, "notes/a.md", "img/a.svg", .link, 1);
    try f.edge(&graph, "notes/a.md", "pages/a(b).md", .link, 1);
}
test "Markdown fences inline code escaped links and HTML comments are ignored" {
    var graph = try (f.Fixture{ .items = &.{
        .{ .path = "a.md", .text =
        \\```md
        \\[[b]]
        \\```
        \\~~~
        \\[b](b.md)
        \\~~~
        \\`[[b]]` ``[b](b.md)`` \[[b]] <!-- [[b]] -->
        \\[[b]]
        },
        .{ .path = "b.md" },
    } }).scan(a, .{ .kinds = &.{.link} });
    defer graph.deinit();
    try f.edge(&graph, "a.md", "b.md", .link, 1);
}
test "ambiguous wiki basename is unresolved but relative links are exact" {
    var graph = try (f.Fixture{ .items = &.{
        .{ .path = "notes/a.md", .text = "[[b]] [[x/b]] [b](../y/b.md) [ambiguous](b.md)" },
        .{ .path = "x/b.md" },
        .{ .path = "y/b.md" },
    } }).scan(a, .{ .kinds = &.{.link} });
    defer graph.deinit();
    try eq(2, graph.edges().len);
    try f.edge(&graph, "notes/a.md", "x/b.md", .link, 1);
    try f.edge(&graph, "notes/a.md", "y/b.md", .link, 1);
}
test "asset tokens resolve root first then relative and never substring match" {
    var graph = try (f.Fixture{ .items = &.{
        .{ .path = "site/index.html", .text = "ximg/a.svg img/a.svg ./local.svg img/a.svg.bak site/index.html" },
        .{ .path = "img/a.svg" },
        .{ .path = "site/local.svg" },
        .{ .path = "site/img/a.svg" },
    } }).scan(a, .{ .kinds = &.{.asset} });
    defer graph.deinit();
    try eq(2, graph.edges().len);
    try f.edge(&graph, "site/index.html", "img/a.svg", .asset, 1);
    try f.edge(&graph, "site/index.html", "site/local.svg", .asset, 1);
}
test "recoverers are explicitly selectable and kinds retain separate counts" {
    var graph = try (f.Fixture{ .items = &.{ .{ .path = "a.md", .text = "[[b]] b.md" }, .{ .path = "b.md" } } }).scan(a, .{ .kinds = &.{ .link, .asset } });
    defer graph.deinit();
    try eq(2, graph.edges().len);
    try f.edge(&graph, "a.md", "b.md", .link, 1);
    try f.edge(&graph, "a.md", "b.md", .asset, 1);
}
