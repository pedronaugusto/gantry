const std = @import("std");
const g = @import("gantry.zig");
const f = @import("test_support.zig");
const a = std.testing.allocator;

test "TS configs inherit JSONC aliases with longest prefix and ordered fallbacks" {
    var graph = try (f.Fixture{ .items = &.{
        .{ .path = "config/base.json", .text = "{ // comment\n\"compilerOptions\": {\"baseUrl\": \"../src\", \"paths\": {\"@/*\": [\"missing/*\", \"lib/*\"], \"@/special/*\": [\"special/*\"], \"exact\": [\"types/api\"],},},}" },
        .{ .path = "src/tsconfig.json", .text = "{\"extends\": \"../config/base\"}" },
        .{ .path = "src/app.ts", .text = "import '@/util'; import '@/special/x'; import 'exact'; import 'bare'; import './runtime.js'; import './esm.mjs'; import './cjs.cjs';" },
        .{ .path = "src/lib/util.ts" },
        .{ .path = "src/lib/special/x.ts" },
        .{ .path = "src/special/x.d.ts" },
        .{ .path = "src/types/api.d.ts" },
        .{ .path = "src/bare/index.d.ts" },
        .{ .path = "src/runtime.js" },
        .{ .path = "src/runtime.d.ts" },
        .{ .path = "src/runtime.ts" },
        .{ .path = "src/esm.d.mts" },
        .{ .path = "src/cjs.d.cts" },
    } }).scan(a, .{});
    defer graph.deinit();
    try f.edge(&graph, "src/app.ts", "src/lib/util.ts", .import, 1);
    try f.edge(&graph, "src/app.ts", "src/special/x.d.ts", .import, 1);
    try f.edge(&graph, "src/app.ts", "src/types/api.d.ts", .import, 1);
    try f.edge(&graph, "src/app.ts", "src/bare/index.d.ts", .import, 1);
    try f.edge(&graph, "src/app.ts", "src/runtime.ts", .import, 1);
    try f.edge(&graph, "src/app.ts", "src/esm.d.mts", .import, 1);
    try f.edge(&graph, "src/app.ts", "src/cjs.d.cts", .import, 1);
    try std.testing.expectEqual(7, graph.edges().len);
}

test "JS config paths without baseUrl and child replacement stay scoped" {
    var graph = try (f.Fixture{ .items = &.{
        .{ .path = "jsconfig.json", .text = "{\"compilerOptions\": {\"paths\": {\"alias\": [\"shared\"]}}}" },
        .{ .path = "app.js", .text = "import 'alias'; import 'shared';" },
        .{ .path = "shared.d.ts" },
        .{ .path = "child/tsconfig.json", .text = "{\"extends\": \"../jsconfig.json\", \"compilerOptions\": {\"paths\": {\"local\": [\"util\"]}}}" },
        .{ .path = "child/app.ts", .text = "import 'alias'; import 'local';" },
        .{ .path = "child/util.ts" },
    } }).scan(a, .{});
    defer graph.deinit();
    try f.edge(&graph, "app.js", "shared.d.ts", .import, 1);
    try f.edge(&graph, "child/app.ts", "child/util.ts", .import, 1);
    try std.testing.expectEqual(2, graph.edges().len);
}

test "TS config cycles fail and unselected extends never call the reader" {
    try std.testing.expectError(error.ConfigCycle, (f.Fixture{ .items = &.{
        .{ .path = "tsconfig.json", .text = "{\"extends\": \"./base.json\"}" },
        .{ .path = "base.json", .text = "{\"extends\": \"./tsconfig.json\"}" },
    } }).scan(a, .{}));
    var graph = try (f.Fixture{ .items = &.{.{ .path = "tsconfig.json", .text = "{\"extends\": \"../outside\"}" }} }).scan(a, .{});
    defer graph.deinit();
}

test "TS config reads stay in a temporary repository and own reader scratch bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "tsconfig.json", .data = "{\"extends\": \"./base.json\"}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "base.json", .data = "{\"compilerOptions\": {\"baseUrl\": \"src\"}}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/app.ts", .data = "import 'util';" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/util.d.ts", .data = "" });
    var graph = try g.scan(a, &.{ "tsconfig.json", "base.json", "src/app.ts", "src/util.d.ts" }, g.DirReader{ .io = io, .dir = tmp.dir }, g.DirReader.read, .{});
    defer graph.deinit();
    try f.edge(&graph, "src/app.ts", "src/util.d.ts", .import, 1);
}
