const std = @import("std");
const g = @import("../gantry.zig");
const f = @import("support.zig");
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

test "TS config cycles are invalid and unselected extends never call the reader" {
    var cycle = try (f.Fixture{ .items = &.{
        .{ .path = "tsconfig.json", .text = "{\"extends\": \"./base.json\"}" },
        .{ .path = "base.json", .text = "{\"extends\": \"./tsconfig.json\"}" },
    } }).scan(a, .{});
    defer cycle.deinit();
    try std.testing.expectEqual(1, cycle.invalid().len);
    try std.testing.expectEqual(error.ConfigCycle, cycle.invalid()[0].cause);
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
    var graph = try g.scan(a, io, &.{ "tsconfig.json", "base.json", "src/app.ts", "src/util.d.ts" }, g.DirReader{ .dir = tmp.dir }, g.DirReader.read, .{});
    defer graph.deinit();
    try f.edge(&graph, "src/app.ts", "src/util.d.ts", .import, 1);
}

test "JSONC config parsing rejects source syntax and unterminated comments" {
    for ([_][]const u8{
        "{} /* unterminated",
        "{} `ignored template`",
        "{} /ignored_regex/",
        "{\"compilerOptions\": {\"baseUrl\": \".\"}} /* unterminated",
    }) |text| {
        var graph = try (f.Fixture{ .items = &.{.{ .path = "tsconfig.json", .text = text }} }).scan(a, .{ .manifests = false });
        defer graph.deinit();
        try f.invalid(&graph, "tsconfig.json", error.SyntaxError);
    }
}

test "JSONC comments and trailing commas preserve strings and inherited aliases" {
    var graph = try (f.Fixture{ .items = &.{
        .{ .path = "tsconfig.json", .text =
        \\{
        \\ "note": "/* ,} */ // escaped \" quote",
        \\ "compilerOptions": {
        \\   "paths": { "alias": [ "dep", /* comment */ ], // line comment
        \\   },
        \\ }, /* final comment */
        \\}
        },
        .{ .path = "app.ts", .text = "import 'alias';" },
        .{ .path = "dep.ts" },
    } }).scan(a, .{ .manifests = false });
    defer graph.deinit();
    try f.edge(&graph, "app.ts", "dep.ts", .import, 1);
}

test "absolute config paths never become relative to the config directory" {
    for ([_][]const u8{
        "{\"compilerOptions\": {\"baseUrl\": \"/src\"}}",
        "{\"compilerOptions\": {\"paths\": {\"dep\": [\"/src/dep\"]}}}",
    }) |text| {
        var graph = try (f.Fixture{ .items = &.{
            .{ .path = "config/tsconfig.json", .text = text },
            .{ .path = "config/app.ts", .text = "import 'dep';" },
            .{ .path = "config/src/dep.ts" },
        } }).scan(a, .{ .manifests = false });
        defer graph.deinit();
        try std.testing.expectEqual(0, graph.edges().len);
        try std.testing.expect(!graph.references()[0].resolved);
    }
}

test "invalid config shapes are recorded rather than silently disabling resolution options" {
    for ([_][]const u8{
        "[]",
        "null",
        "{\"extends\": false}",
        "{\"extends\": [\"./base\", 42]}",
        "{\"compilerOptions\": []}",
        "{\"compilerOptions\": {\"baseUrl\": false}}",
        "{\"compilerOptions\": {\"paths\": []}}",
        "{\"compilerOptions\": {\"paths\": {\"alias\": [42]}}}",
    }) |text| {
        var graph = try (f.Fixture{ .items = &.{.{ .path = "tsconfig.json", .text = text }} }).scan(a, .{ .manifests = false });
        defer graph.deinit();
        try f.invalid(&graph, "tsconfig.json", error.InvalidConfig);
    }
}

test "TS path aliases reach type-only imports and import types in declaration files" {
    // VS Code's `vs/*` alias from src/tsconfig.base.json and the import forms
    // its bootstrap and webview declaration files use.
    var graph = try (f.Fixture{ .items = &.{
        .{ .path = "src/tsconfig.json", .text = "{\"extends\": \"./tsconfig.base.json\"}" },
        .{ .path = "src/tsconfig.base.json", .text = "{\"compilerOptions\": {\"baseUrl\": \".\", \"paths\": {\"vs/*\": [\"./vs/*\"]}}}" },
        .{ .path = "src/bootstrap-window.ts", .text = "(function () {\n\ttype C = import('vs/base/common/sandboxTypes.js').C;\n\ttype W = import('vs/window/common/window.ts').W;\n}());" },
        .{ .path = "src/vs/webview/webviewMessages.d.ts", .text = "import type { E } from 'vs/base/browser/mouseEvent';\n" },
        .{ .path = "src/vs/base/common/sandboxTypes.ts" },
        .{ .path = "src/vs/window/common/window.ts" },
        .{ .path = "src/vs/base/browser/mouseEvent.ts" },
    } }).scan(a, .{ .manifests = false });
    defer graph.deinit();
    try f.edge(&graph, "src/bootstrap-window.ts", "src/vs/base/common/sandboxTypes.ts", .type_only, 1);
    try f.edge(&graph, "src/bootstrap-window.ts", "src/vs/window/common/window.ts", .type_only, 1);
    try f.edge(&graph, "src/vs/webview/webviewMessages.d.ts", "src/vs/base/browser/mouseEvent.ts", .type_only, 1);
    try std.testing.expectEqual(3, graph.edges().len);
}

test "an empty or truncated config is a syntax error like any other" {
    // Found by the config fuzz property: the JSON reader's own errors
    // escaped the scan for input that ends early.
    for ([_][]const u8{ "", "{\"compilerOptions\": ", "{\"a\": \"x", "[" }) |text| {
        var graph = try (f.Fixture{ .items = &.{.{ .path = "tsconfig.json", .text = text }} }).scan(a, .{ .manifests = false });
        defer graph.deinit();
        try f.invalid(&graph, "tsconfig.json", error.SyntaxError);
    }
}
