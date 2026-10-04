const std = @import("std");
const g = @import("../gantry.zig");
const f = @import("../testing/support.zig");
const a = std.testing.allocator;
const eq = std.testing.expectEqual;

test "fixture: a Nim project resolves sources, groups, includes, its tests' search path and requirements" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const items = [_]f.Item{
        .{ .path = "src/app.nim", .text = "import std/os, app/[util, net]\ninclude app/inc\nimport strutils" },
        .{ .path = "src/app/util.nim", .text = "import ./net\nfrom ../app/net import send" },
        .{ .path = "src/app/net.nim", .text = "when defined(windows):\n  import winlean\nelse:\n  import posix" },
        .{ .path = "src/app/inc.nim", .text = "proc included() = discard" },
        .{ .path = "tests/config.nims", .text = "switch(\"path\", \"../src\")" },
        .{ .path = "tests/tapp.nim", .text = "import app, app/util\nimport unittest" },
        .{ .path = "app.nimble", .text = "srcDir = \"src\"\nrequires \"nim >= 2.0\", \"jester#head\"\ntaskRequires \"test\", \"unittest2\"" },
    };
    try tmp.dir.createDirPath(io, "src/app");
    try tmp.dir.createDirPath(io, "tests");
    var paths: [items.len][]const u8 = undefined;
    for (items, &paths) |item, *path| {
        path.* = item.path;
        try tmp.dir.writeFile(io, .{ .sub_path = item.path, .data = item.text.? });
    }
    var graph = try g.scan(a, &paths, g.DirReader{ .io = io, .dir = tmp.dir }, g.DirReader.read, .{});
    defer graph.deinit();
    try f.edge(&graph, "src/app.nim", "src/app/util.nim", .import, 1);
    try f.edge(&graph, "src/app.nim", "src/app/net.nim", .import, 1);
    try f.edge(&graph, "src/app.nim", "src/app/inc.nim", .import, 1);
    try f.edge(&graph, "src/app/util.nim", "src/app/net.nim", .import, 2);
    try f.edge(&graph, "tests/tapp.nim", "src/app.nim", .@"test", 1);
    try f.edge(&graph, "tests/tapp.nim", "src/app/util.nim", .@"test", 1);
    try eq(6, graph.edges().len);
    try eq(0, graph.unsupported().len);
    var unresolved: usize = 0;
    for (graph.references()) |ref| if (!ref.resolved) {
        unresolved += 1;
    };
    // std/os, strutils, winlean, posix, unittest
    try eq(5, unresolved);
    try eq(2, graph.dependencies().len);
    try std.testing.expectEqualStrings("jester", graph.dependencies()[0].name);
    try std.testing.expectEqualStrings("head", graph.dependencies()[0].revision());
    try eq(g.Dependency.Scope.development, graph.dependencies()[1].scope());
}

test "Nim std names only the standard library and pkg only search paths" {
    var graph = try (f.Fixture{ .items = &.{
        .{ .path = "nim.cfg", .text = "--path:\"vendor\"" },
        .{ .path = "a.nim", .text = "import std/os, pkg/b, c, ./d, ../e" },
        .{ .path = "std/os.nim" },
        .{ .path = "b.nim" },
        .{ .path = "vendor/b.nim" },
        .{ .path = "vendor/c.nim" },
        .{ .path = "vendor/d.nim" },
    } }).scan(a, .{});
    defer graph.deinit();
    try f.edge(&graph, "a.nim", "vendor/b.nim", .import, 1);
    try f.edge(&graph, "a.nim", "vendor/c.nim", .import, 1);
    try eq(2, graph.edges().len);
}

test "Nim finds a module beside the importer first, then the nearest and latest search path" {
    var graph = try (f.Fixture{ .items = &.{
        .{ .path = "nim.cfg", .text = "path = \"outer\"" },
        .{ .path = "app/config.nims", .text = "switch(\"path\", \"first\")\n--path:\"second\"" },
        .{ .path = "app/main.nim", .text = "import here, shared, deep\ninclude \"part.inc\"" },
        .{ .path = "app/here.nim" },
        .{ .path = "outer/here.nim" },
        .{ .path = "outer/shared.nim" },
        .{ .path = "outer/deep.nim" },
        .{ .path = "app/first/shared.nim" },
        .{ .path = "app/second/shared.nim" },
        .{ .path = "app/part.inc" },
        .{ .path = "other/main.nim", .text = "import shared" },
    } }).scan(a, .{});
    defer graph.deinit();
    try f.edge(&graph, "app/main.nim", "app/here.nim", .import, 1);
    try f.edge(&graph, "app/main.nim", "app/second/shared.nim", .import, 1);
    try f.edge(&graph, "app/main.nim", "outer/deep.nim", .import, 1);
    try f.edge(&graph, "app/main.nim", "app/part.inc", .import, 1);
    try f.edge(&graph, "other/main.nim", "outer/shared.nim", .import, 1);
    try eq(5, graph.edges().len);
}

test "Nim configs read literal paths and leave substitutions, computed values and comments" {
    var graph = try (f.Fixture{ .items = &.{
        .{ .path = "nim.cfg", .text =
        \\# --path:"commented"
        \\--path:"a"
        \\-p:b
        \\P_ath: "c"
        \\path = "$projectDir/d"
        \\@if windows:
        \\  --path:"e"
        \\@end
        \\--define:release
        },
        .{ .path = "x/app.nims", .text =
        \\switch("path", thisDir() & "/f")
        \\--path:"g" & "h"
        \\# switch("path", "i")
        \\switch("p", "j")
        },
        .{ .path = "main.nim", .text = "import one, two, three, four, five" },
        .{ .path = "x/main.nim", .text = "import six, seven, nine, ten" },
        .{ .path = "a/one.nim" },
        .{ .path = "b/two.nim" },
        .{ .path = "c/three.nim" },
        .{ .path = "d/four.nim" },
        .{ .path = "e/five.nim" },
        .{ .path = "x/f/six.nim" },
        .{ .path = "x/g/seven.nim" },
        .{ .path = "x/i/nine.nim" },
        .{ .path = "x/j/ten.nim" },
    } }).scan(a, .{});
    defer graph.deinit();
    try f.edge(&graph, "main.nim", "a/one.nim", .import, 1);
    try f.edge(&graph, "main.nim", "b/two.nim", .import, 1);
    try f.edge(&graph, "main.nim", "c/three.nim", .import, 1);
    // conditions are not evaluated: every literal path counts
    try f.edge(&graph, "main.nim", "e/five.nim", .import, 1);
    try f.edge(&graph, "x/main.nim", "x/j/ten.nim", .import, 1);
    try eq(5, graph.edges().len);
}

test "Nim test files sit in tests folders or start with test" {
    var graph = try (f.Fixture{ .items = &.{
        .{ .path = "tests/tfoo.nim", .text = "import ../lib" },
        .{ .path = "tests/helper.nim", .text = "import ../lib" },
        .{ .path = "test_bar.nim", .text = "import lib" },
        .{ .path = "lib.nim" },
    } }).scan(a, .{});
    defer graph.deinit();
    try f.edge(&graph, "tests/tfoo.nim", "lib.nim", .@"test", 1);
    try f.edge(&graph, "tests/helper.nim", "lib.nim", .import, 1);
    try f.edge(&graph, "test_bar.nim", "lib.nim", .@"test", 1);
}
