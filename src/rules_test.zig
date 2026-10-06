const std = @import("std");
const g = @import("gantry.zig");
const f = @import("testing/support.zig");
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
    var findings_owned = try graph.check(a, .{
        .ordered = &.{.{ .name = "layers", .layers = &.{
            .{ .name = "leaves", .patterns = &.{} }, .{ .name = "station", .patterns = &.{"daemon/station.zig"} }, .{ .name = "entry", .patterns = &.{"daemon/main.zig"} }, .{ .name = "tests", .patterns = &.{"daemon/tests.zig"} },
        } }},
        .nothing_imports = &.{.{ .name = "entry", .to = "**/main.zig" }},
        .allowed = &.{.{ .rule = "entry", .from = "daemon/tests.zig", .to = "daemon/main.zig" }},
        .required = &.{.{ .name = "named modules", .paths = &.{ "daemon/station.zig", "daemon/missing.zig" } }},
        .no_cycles = "acyclic",
    });
    defer findings_owned.deinit();
    const findings = findings_owned.items();
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
    var findings_owned = try graph.check(a, .{
        .forbidden = &.{ .{ .name = "first" }, .{ .name = "second", .kind = .import } },
        .allowed = &.{.{ .rule = "first", .from = "a", .to = "b" }},
    });
    defer findings_owned.deinit();
    const findings = findings_owned.items();
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
    var findings_owned = try graph.check(a, .{
        .forbidden = &.{.{ .name = "proto siblings", .from = "proto/**", .to = "**" }},
        .allowed = &.{.{ .rule = "proto siblings", .from = "proto/**", .to = "proto/*" }},
        .references = &.{
            .{ .name = "proto packages", .from = "proto/**", .unresolved_only = true, .except_targets = &.{ "std", "strand" } },
            .{ .name = "watcher owner", .target = "lookout", .except_from = &.{"daemon/filewatch.zig"} },
            .{ .name = "client mirror", .from = "daemon/**", .target = "proto", .member = "mirror" },
        },
    });
    defer findings_owned.deinit();
    const findings = findings_owned.items();
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
    var findings_owned = try graph.check(a, .{ .ordered = &.{.{ .name = "layers", .layers = &.{ .{ .name = "empty", .patterns = &.{} }, .{ .name = "high", .patterns = &.{"high"} }, .{ .name = "fallback", .patterns = &.{"**"} } } }} });
    defer findings_owned.deinit();
    const findings = findings_owned.items();
    try eq(1, findings.len);
    try std.testing.expectEqualStrings("high", findings[0].edge.?.from);
}

test "raw import name rules are exact across package paths" {
    var graph = try (f.Fixture{ .items = &.{.{ .path = "a.ts", .text = "import 'lookout'; import 'vendor/lookout';" }} }).scan(a, .{});
    defer graph.deinit();
    var findings_owned = try graph.check(a, .{ .references = &.{.{ .name = "owner", .target = "lookout" }} });
    defer findings_owned.deinit();
    const findings = findings_owned.items();
    try eq(1, findings.len);
    try std.testing.expectEqualStrings("lookout", findings[0].reference.?.name);
}
test "fixture: proto sibling boundary covers unresolved and normalized literal paths" {
    var graph = try (f.Fixture{ .items = &.{.{ .path = "proto/root.zig", .text = "const a = @import(\"./ok.zig\"); const b = @import(\"x/../ok.zig\"); const c = @import(\"../daemon/missing.zig\"); const d = @import(\"nested/missing.zig\"); const s = @import(\"std\");" }} }).scan(a, .{});
    defer graph.deinit();
    var findings_owned = try graph.check(a, .{ .references = &.{.{ .name = "siblings", .from = "proto/*", .suffix = ".zig", .relative = true, .except_targets = &.{"proto/*.zig"} }} });
    defer findings_owned.deinit();
    const findings = findings_owned.items();
    try eq(2, findings.len);
    try std.testing.expectEqualStrings("../daemon/missing.zig", findings[0].reference.?.name);
    try std.testing.expectEqualStrings("nested/missing.zig", findings[1].reference.?.name);
}

fn expectChain(want: []const []const u8, got: []const []const u8) !void {
    try eq(want.len, got.len);
    for (want, got) |w, x| try std.testing.expectEqualStrings(w, x);
}

test "a transitive rule catches the chain one intermediate file hides from a direct rule" {
    var graph = try g.Graph.fromEdges(a, &.{ "ui/view.zig", "ui/panel.zig", "core/model.zig", "core/cache.zig", "db/store.zig", "db/index.zig", "ui/alone.zig" }, &.{
        .{ .from = "ui/view.zig", .to = "core/model.zig" },
        .{ .from = "core/model.zig", .to = "db/store.zig" },
        .{ .from = "ui/view.zig", .to = "core/cache.zig" },
        .{ .from = "core/cache.zig", .to = "db/index.zig" },
        .{ .from = "ui/panel.zig", .to = "db/index.zig", .kind = .type_only },
        .{ .from = "db/store.zig", .to = "db/index.zig" },
    });
    defer graph.deinit();
    // The direct rule sees only ui/panel's edge.
    var direct_owned = try graph.check(a, .{ .forbidden = &.{.{ .name = "ui to db", .from = "ui/**", .to = "db/**" }} });
    defer direct_owned.deinit();
    const direct = direct_owned.items();
    try eq(1, direct.len);
    try std.testing.expectEqualStrings("ui/panel.zig", direct[0].edge.?.from);
    try eq(0, direct[0].chain.len);

    var findings_owned = try graph.check(a, .{ .forbidden = &.{.{ .name = "ui to db", .from = "ui/**", .to = "db/**", .transitive = true }} });
    defer findings_owned.deinit();
    const findings = findings_owned.items();
    try eq(2, findings.len);
    // Two chains of two edges: the first path at each position wins.
    try expectChain(&.{ "ui/panel.zig", "db/index.zig" }, findings[0].chain);
    try expectChain(&.{ "ui/view.zig", "core/cache.zig", "db/index.zig" }, findings[1].chain);
    try eq(.forbidden, findings[1].reason);
    try std.testing.expectEqualStrings("core/cache.zig", findings[1].edge.?.to);
    try std.testing.expectEqualStrings("db/index.zig", findings[1].path.?);

    // An allowance takes its edges out of the chains; a kind narrows them.
    var allowed_owned = try graph.check(a, .{
        .forbidden = &.{ .{ .name = "ui to db", .from = "ui/**", .to = "db/**", .transitive = true }, .{ .name = "values", .from = "ui/**", .to = "db/**", .kind = .type_only, .transitive = true } },
        .allowed = &.{ .{ .rule = "ui to db", .from = "core/cache.zig" }, .{ .rule = "ui to db", .kind = .type_only } },
    });
    defer allowed_owned.deinit();
    const allowed = allowed_owned.items();
    try eq(2, allowed.len);
    try expectChain(&.{ "ui/view.zig", "core/model.zig", "db/store.zig" }, allowed[0].chain);
    try std.testing.expectEqualStrings("values", allowed[1].rule);
    try expectChain(&.{ "ui/panel.zig", "db/index.zig" }, allowed[1].chain);
}

test "a transitive chain stops at its first target and a file in both sets needs an edge" {
    var graph = try g.Graph.fromEdges(a, &.{ "x/a", "x/b", "x/c" }, &.{
        .{ .from = "x/a", .to = "x/b" },
        .{ .from = "x/b", .to = "x/c" },
    });
    defer graph.deinit();
    var findings_owned = try graph.check(a, .{ .forbidden = &.{.{ .name = "inside", .from = "x/*", .to = "x/*", .transitive = true }} });
    defer findings_owned.deinit();
    const findings = findings_owned.items();
    try eq(2, findings.len);
    try expectChain(&.{ "x/a", "x/b" }, findings[0].chain);
    try expectChain(&.{ "x/b", "x/c" }, findings[1].chain);
}

test "transitive layers report chains through unlayered files, once per file and higher layer" {
    var graph = try g.Graph.fromEdges(a, &.{ "low/a", "low/b", "util/u", "util/v", "mid/m", "high/h" }, &.{
        .{ .from = "low/a", .to = "util/u" },
        .{ .from = "util/u", .to = "util/v" },
        .{ .from = "util/v", .to = "high/h" },
        .{ .from = "util/u", .to = "mid/m" },
        .{ .from = "low/b", .to = "mid/m" },
        .{ .from = "mid/m", .to = "high/h" },
        .{ .from = "high/h", .to = "util/u" },
    });
    defer graph.deinit();
    const layers = [_]g.rules.Layer{
        .{ .name = "low", .patterns = &.{"low/**"} },
        .{ .name = "mid", .patterns = &.{"mid/**"} },
        .{ .name = "high", .patterns = &.{"high/**"} },
    };
    // Directly, util is the default (lowest) layer: its edges up are found,
    // but not that low/a reaches high through it.
    var direct_owned = try graph.check(a, .{ .ordered = &.{.{ .name = "layers", .layers = &layers }} });
    defer direct_owned.deinit();
    const direct = direct_owned.items();
    try eq(4, direct.len);
    var findings_owned = try graph.check(a, .{ .ordered = &.{.{ .name = "layers", .layers = &layers, .transitive = true }} });
    defer findings_owned.deinit();
    const findings = findings_owned.items();
    try eq(4, findings.len);
    try expectChain(&.{ "low/a", "util/u", "mid/m" }, findings[0].chain);
    try expectChain(&.{ "low/a", "util/u", "util/v", "high/h" }, findings[1].chain);
    try expectChain(&.{ "low/b", "mid/m" }, findings[2].chain);
    // low/b reaches high only through mid, a layered file: that chain is mid's.
    try expectChain(&.{ "mid/m", "high/h" }, findings[3].chain);
    try eq(.upward, findings[3].reason);
    try std.testing.expectEqualStrings("high/h", findings[3].path.?);
}

test "files no chain from an entry reaches are unreached, orphans included" {
    var graph = try g.Graph.fromEdges(a, &.{ "src/main.zig", "src/used.zig", "src/deep.zig", "src/orphan.zig", "src/fixture.zig", "src/main_test.zig", "docs/x.md" }, &.{
        .{ .from = "src/main.zig", .to = "src/used.zig" },
        .{ .from = "src/used.zig", .to = "src/deep.zig" },
        .{ .from = "src/main_test.zig", .to = "src/fixture.zig", .kind = .@"test" },
        .{ .from = "src/main.zig", .to = "src/main_test.zig", .kind = .@"test" },
    });
    defer graph.deinit();
    var findings_owned = try graph.check(a, .{ .reachable = &.{
        .{ .name = "reached", .entries = &.{"src/main.zig"}, .files = "src/**" },
        .{ .name = "shipped", .entries = &.{"**/main.zig"}, .files = "src/**", .kind = .import },
    } });
    defer findings_owned.deinit();
    const findings = findings_owned.items();
    try eq(4, findings.len);
    try std.testing.expectEqualStrings("src/orphan.zig", findings[0].path.?);
    try eq(.unreached, findings[0].reason);
    try std.testing.expectEqualStrings("shipped", findings[1].rule);
    try std.testing.expectEqualStrings("src/fixture.zig", findings[1].path.?);
    try std.testing.expectEqualStrings("src/main_test.zig", findings[2].path.?);
    try std.testing.expectEqualStrings("src/orphan.zig", findings[3].path.?);
}

test "transitive findings agree with an independent nearest-target search" {
    const n = 10;
    const paths = &[_][]const u8{ "a0", "a1", "a2", "a3", "a4", "b0", "b1", "b2", "b3", "b4" };
    const far = std.math.maxInt(usize) / 4;
    var random: std.Random.DefaultPrng = .init(0x7265616368);
    for (0..128) |_| {
        var list: std.ArrayList(g.Edge) = .empty;
        defer list.deinit(a);
        var direct: [n][n]bool = @splat(@splat(false));
        for (0..n) |v| for (0..n) |w| if (random.random().uintLessThan(u8, 10) < 2) {
            direct[v][w] = true;
            try list.append(a, .{ .from = paths[v], .to = paths[w] });
        };
        // Distance to the nearest b file, chains stopping at the first one.
        var near: [n]usize = @splat(far);
        for (5..n) |v| near[v] = 0;
        for (0..n) |_| for (0..n) |v| if (v < 5) for (0..n) |w| if (direct[v][w]) {
            near[v] = @min(near[v], near[w] + 1);
        };
        var graph = try g.Graph.fromEdges(a, paths, list.items);
        defer graph.deinit();
        var findings_owned = try graph.check(a, .{ .forbidden = &.{.{ .name = "a to b", .from = "a*", .to = "b*", .transitive = true }} });
        defer findings_owned.deinit();
        const findings = findings_owned.items();
        var k: usize = 0;
        for (0..5) |v| {
            var best: usize = far;
            for (0..n) |w| if (direct[v][w]) {
                best = @min(best, near[w] + 1);
            };
            if (best >= far) continue;
            const chain = findings[k].chain;
            k += 1;
            try eq(best + 1, chain.len);
            try std.testing.expectEqualStrings(paths[v], chain[0]);
            try eq('b', chain[chain.len - 1][0]);
            for (chain[0 .. chain.len - 1], chain[1..]) |from, to| try std.testing.expect(direct[from[1] - '0' + @as(usize, if (from[0] == 'b') 5 else 0)][to[1] - '0' + @as(usize, if (to[0] == 'b') 5 else 0)]);
        }
        try eq(k, findings.len);
    }
}
test "path patterns: ** is a whole component, a/** matches a, a slashless pattern the base name" {
    const m = g.rules.matches;
    try std.testing.expect(m("a/**", "a"));
    try std.testing.expect(m("a/**", "a/b/c"));
    try std.testing.expect(m("a/**/c", "a/c"));
    try std.testing.expect(!m("a**/c", "ax/y/c"));
    try std.testing.expect(m("a**/c", "ax/c"));
    try std.testing.expect(m("*.zig", "src/x/a.zig"));
    try std.testing.expect(!m("src/*.zig", "src/x/a.zig"));
}
