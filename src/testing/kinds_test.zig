const std = @import("std");
const g = @import("../gantry.zig");
const f = @import("support.zig");
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
    try std.testing.expectEqual(2, production.edges().len);
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

test "Rust test propagation reads each source once and releases reader scratch" {
    const Reader = struct {
        calls: usize = 0,
        fn read(self: *@This(), name: []const u8, scratch: std.mem.Allocator) !?[]const u8 {
            self.calls += 1;
            return try scratch.dupe(u8, if (std.mem.eql(u8, name, "src/lib.rs")) "#[cfg(test)] mod helper;" else if (std.mem.eql(u8, name, "src/helper.rs")) "mod child; use crate::util;" else if (std.mem.eql(u8, name, "src/helper/child.rs")) "use crate::util;" else "");
        }
    };
    var reader: Reader = .{};
    var graph = try g.scan(a, &.{ "src/lib.rs", "src/helper.rs", "src/helper/child.rs", "src/util.rs" }, &reader, Reader.read, .{});
    defer graph.deinit();
    try f.edge(&graph, "src/helper.rs", "src/util.rs", .@"test", 1);
    try f.edge(&graph, "src/helper/child.rs", "src/util.rs", .@"test", 1);
    try std.testing.expectEqual(4, reader.calls);
}
test "kindsOf says which references a scan reads from a path by its name" {
    const K = g.Kind;
    const zig = g.kindsOf("src/main.zig");
    try std.testing.expect(zig.contains(K.import) and zig.contains(K.@"test") and !zig.contains(K.link) and !zig.contains(K.asset));
    const md = g.kindsOf("notes/a.md");
    try std.testing.expect(md.contains(K.link) and md.contains(K.asset) and !md.contains(K.import));
    const json = g.kindsOf("data/x.json");
    try std.testing.expect(json.contains(K.asset) and !json.contains(K.link) and !json.contains(K.import));
    const nim = g.kindsOf("src/app.nim");
    try std.testing.expect(nim.contains(K.import) and nim.contains(K.@"test") and !nim.contains(K.asset));
    try std.testing.expectEqual(@as(usize, 0), g.kindsOf("config.nims").count());
    try std.testing.expectEqual(@as(usize, 0), g.kindsOf("image.png").count());
}

test "TypeScript type-only imports and dynamic imports are edges of their own kinds" {
    const fixture: f.Fixture = .{ .items = &.{
        .{ .path = "app.ts", .text =
        \\import type { Model } from './model';
        \\import { type A, type B } from './types';
        \\import { type C, value } from './mixed';
        \\import type from './named';
        \\import type, { other } from './named2';
        \\export type * from './reexport';
        \\export { type D } from './reexport2';
        \\import type Old = require('./legacy');
        \\const lazy = import('./lazy');
        \\type Shape = typeof import('./shape');
        \\let t: import('./types2').T;
        \\import('./later').then((m) => m);
        \\import './side';
        },
        .{ .path = "model.ts" },
        .{ .path = "types.ts" },
        .{ .path = "mixed.ts" },
        .{ .path = "named.ts" },
        .{ .path = "named2.ts" },
        .{ .path = "reexport.ts" },
        .{ .path = "reexport2.ts" },
        .{ .path = "legacy.ts" },
        .{ .path = "lazy.ts" },
        .{ .path = "shape.ts" },
        .{ .path = "types2.ts" },
        .{ .path = "later.ts" },
        .{ .path = "side.ts" },
    } };
    var graph = try fixture.scan(a, .{});
    defer graph.deinit();
    for ([_][]const u8{ "model.ts", "types.ts", "reexport.ts", "reexport2.ts", "legacy.ts", "shape.ts", "types2.ts" }) |to| try f.edge(&graph, "app.ts", to, .type_only, 1);
    for ([_][]const u8{ "lazy.ts", "later.ts" }) |to| try f.edge(&graph, "app.ts", to, .dynamic, 1);
    for ([_][]const u8{ "mixed.ts", "named.ts", "named2.ts", "side.ts" }) |to| try f.edge(&graph, "app.ts", to, .import, 1);
    try std.testing.expectEqual(13, graph.edges().len);
    var kinds: std.EnumSet(g.Kind) = .initEmpty();
    for (graph.references()) |ref| kinds.insert(ref.kind);
    try std.testing.expect(kinds.contains(.type_only) and kinds.contains(.dynamic) and kinds.contains(.import));

    // Static edges alone; references keep every kind.
    var static = try fixture.scan(a, .{ .kinds = &.{.import} });
    defer static.deinit();
    try std.testing.expectEqual(4, static.edges().len);
    try std.testing.expectEqual(graph.references().len, static.references().len);

    // The usual exception to a layer rule: type-only edges.
    const findings = try graph.check(a, .{
        .forbidden = &.{.{ .name = "values only", .to = "types*.ts" }},
        .allowed = &.{.{ .rule = "values only", .kind = .type_only }},
    });
    defer a.free(findings);
    try std.testing.expectEqual(0, findings.len);
    try std.testing.expect(g.kindsOf("app.ts").contains(.dynamic));
    try std.testing.expect(!g.kindsOf("main.zig").contains(.type_only));
}

test "a test file's type-only import is a test edge" {
    var graph = try (f.Fixture{ .items = &.{
        .{ .path = "app.spec.ts", .text = "import type { A } from './a'; const b = import('./b');" },
        .{ .path = "a.ts" },
        .{ .path = "b.ts" },
    } }).scan(a, .{});
    defer graph.deinit();
    try f.edge(&graph, "app.spec.ts", "a.ts", .@"test", 1);
    try f.edge(&graph, "app.spec.ts", "b.ts", .@"test", 1);
}
