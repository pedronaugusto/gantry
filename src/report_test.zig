const std = @import("std");
const g = @import("gantry.zig");
const f = @import("testing/support.zig");
const a = std.testing.allocator;
const eq = std.testing.expectEqual;
const expect = std.testing.expect;
const report = g.report;

const paths: []const []const u8 = &.{ "README.md", "assets/logo.svg", "docs/guide.md", "src/lang/c.zig", "src/lang/zig.zig", "src/main.zig", "src/model.zig", "src/store.zig", "tests/main_test.zig" };
const edges: []const g.Edge = &.{
    .{ .from = "src/main.zig", .to = "src/store.zig", .count = 2 },
    .{ .from = "src/store.zig", .to = "src/model.zig" },
    .{ .from = "src/model.zig", .to = "src/store.zig", .kind = .type_only },
    .{ .from = "src/main.zig", .to = "src/lang/zig.zig", .kind = .dynamic },
    .{ .from = "src/lang/zig.zig", .to = "src/lang/c.zig" },
    .{ .from = "src/lang/c.zig", .to = "src/store.zig" },
    .{ .from = "tests/main_test.zig", .to = "src/main.zig", .kind = .@"test" },
    .{ .from = "README.md", .to = "docs/guide.md", .kind = .link },
    .{ .from = "docs/guide.md", .to = "assets/logo.svg", .kind = .asset },
};
const rules: g.rules.Rules = .{
    .forbidden = &.{
        .{ .name = "lang is a leaf", .from = "src/lang/**", .to = "src/store.zig" },
        .{ .name = "main reaches no model", .from = "src/main.zig", .to = "src/model.zig", .transitive = true },
    },
    .nothing_imports = &.{.{ .name = "entry files", .to = "**/main.zig" }},
    .required = &.{.{ .name = "named sources", .paths = &.{"src/root.zig"} }},
    .reachable = &.{.{ .name = "reached docs", .entries = &.{"src/main.zig"}, .files = "docs/**" }},
    .no_cycles = "cycles",
};
const layers: []const g.rules.Layer = &.{
    .{ .name = "lang", .patterns = &.{"src/lang/**"} },
    .{ .name = "core", .patterns = &.{ "src/store.zig", "src/model.zig" } },
    .{ .name = "entry", .patterns = &.{"src/main.zig"} },
};

fn drawn(comptime draw: anytype, graph: *const g.Graph, options: report.Options) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    try draw(a, &out.writer, graph, options);
    return out.toOwnedSlice();
}
fn golden(comptime name: []const u8, actual: []const u8) !void {
    try std.testing.expectEqualStrings(@embedFile("testing/golden/" ++ name), actual);
}

test "dot and mermaid draw nodes, kinds, clusters and findings as their goldens" {
    var graph = try g.Graph.fromEdges(a, paths, edges);
    defer graph.deinit();
    var findings_owned = try graph.check(a, rules);
    defer findings_owned.deinit();
    const findings = findings_owned.items();
    const cases = .{
        .{ "graph", report.Options{ .findings = findings } },
        .{ "directories", report.Options{ .cluster = .directory, .findings = findings } },
        .{ "layers", report.Options{ .cluster = .layer, .layers = layers } },
    };
    inline for (cases) |case| {
        const d = try drawn(report.dot, &graph, case[1]);
        defer a.free(d);
        try golden(case[0] ++ ".dot", d);
        const m = try drawn(report.mermaid, &graph, case[1]);
        defer a.free(m);
        try golden(case[0] ++ ".mmd", m);
    }
}

test "json and sarif write the graph and findings as their goldens" {
    var graph = try g.Graph.fromEdges(a, paths, edges);
    defer graph.deinit();
    var findings_owned = try graph.check(a, rules);
    defer findings_owned.deinit();
    const findings = findings_owned.items();
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try report.json(&out.writer, &graph, findings);
    try golden("graph.json", out.written());
    out.clearRetainingCapacity();
    try report.sarif(a, &out.writer, findings, .{ .uri_prefix = "lib/" });
    try golden("graph.sarif", out.written());
}

test "sarif with source places reference and token findings at a line and code point column" {
    const token: g.rules.TokenRule = .{ .name = "os calls", .tokens = &.{"CreateFileW"}, .owners = &.{"src/os/**"} };
    const fixture: f.Fixture = .{ .items = &.{
        .{ .path = "src/app.zig", .text = "const std = @import(\"std\");\n\nconst s = \"héllo\"; const w = @import(\"lookout\");\nconst c = CreateFileW;\n" },
        .{ .path = "src/os/win.zig", .text = "const c = CreateFileW;\n" },
    } };
    var graph = try fixture.scan(a, .{ .tokens = &.{token} });
    defer graph.deinit();
    var findings_owned = try graph.check(a, .{
        .references = &.{.{ .name = "watcher owner", .target = "lookout" }},
        .tokens = &.{token},
    });
    defer findings_owned.deinit();
    const findings = findings_owned.items();
    try eq(2, findings.len);
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try report.sarifWithSource(a, &out.writer, findings, fixture, f.Fixture.read, .{});
    try golden("source.sarif", out.written());
    // Without source, a token keeps its line and a reference is about its file.
    out.clearRetainingCapacity();
    try report.sarif(a, &out.writer, findings, .{});
    try expect(std.mem.find(u8, out.written(), "\"region\": {\"startLine\": 4}") != null);
    try eq(1, std.mem.count(u8, out.written(), "\"region\""));
}

test "sarif with source keeps a finding whose file reads null or is shorter than its offset" {
    var graph = try g.Graph.fromEdges(a, &.{"a.zig"}, &.{});
    defer graph.deinit();
    const references = [_]g.Reference{
        .{ .from = "a.zig", .name = "x", .offset = 3 },
        .{ .from = "gone.zig", .name = "y", .offset = 0 },
    };
    const findings = [_]g.rules.Violation{
        .{ .rule = "r", .reason = .reference, .reference = &references[0] },
        .{ .rule = "r", .reason = .reference, .reference = &references[1] },
    };
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try report.sarifWithSource(a, &out.writer, &findings, {}, struct {
        fn read(_: std.mem.Allocator, _: void, p: []const u8) !?[]const u8 {
            return if (std.mem.eql(u8, p, "a.zig")) "ab" else null;
        }
    }.read, .{});
    try eq(0, std.mem.count(u8, out.written(), "\"region\""));
    try std.testing.expectError(error.Unreadable, report.sarifWithSource(a, &out.writer, &findings, {}, struct {
        fn read(_: std.mem.Allocator, _: void, _: []const u8) !?[]const u8 {
            return error.Unreadable;
        }
    }.read, .{}));
}

const hostile: []const []const u8 = &.{ "a b/#hash&<tag>`tick`.zig", "bad\xffbyte.zig", "new\nline.zig", "pct%20.zig", "q\"uote.zig", "tab\there.zig", "ünï/cödé.zig" };
const hostile_rules: g.rules.Rules = .{
    .forbidden = &.{.{ .name = "rule \"quoted\"\nsecond line", .to = "q\"uote.zig" }},
    .required = &.{.{ .name = "named", .paths = &.{"missing \"x\".zig"} }},
};

fn hostileGraph() !g.Graph {
    var list: [hostile.len]g.Edge = undefined;
    for (hostile, 0..) |p, i| list[i] = .{ .from = p, .to = hostile[(i + 1) % hostile.len] };
    return g.Graph.fromEdges(a, hostile, &list);
}

test "hostile paths and rule names are escaped in every report as their goldens" {
    var graph = try hostileGraph();
    defer graph.deinit();
    var findings_owned = try graph.check(a, hostile_rules);
    defer findings_owned.deinit();
    const findings = findings_owned.items();
    try eq(2, findings.len);
    const d = try drawn(report.dot, &graph, .{ .cluster = .directory, .findings = findings });
    defer a.free(d);
    try golden("hostile.dot", d);
    const m = try drawn(report.mermaid, &graph, .{ .cluster = .directory, .findings = findings });
    defer a.free(m);
    try golden("hostile.mmd", m);
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try report.json(&out.writer, &graph, findings);
    try golden("hostile.json", out.written());
    out.clearRetainingCapacity();
    try report.sarif(a, &out.writer, findings, .{});
    try golden("hostile.sarif", out.written());
}

test "hostile paths: dot quotes close, ids stay distinct and no raw control byte is written" {
    var graph = try hostileGraph();
    defer graph.deinit();
    const d = try drawn(report.dot, &graph, .{});
    defer a.free(d);
    var ids: std.ArrayList([]const u8) = .empty;
    defer ids.deinit(a);
    var lines = std.mem.splitScalar(u8, d, '\n');
    while (lines.next()) |line| {
        var quoted = false;
        var start: usize = 0;
        var i: usize = 0;
        while (i < line.len) : (i += 1) {
            try expect(line[i] >= 0x20 and line[i] != 0x7f);
            if (quoted and line[i] == '\\') {
                i += 1;
            } else if (line[i] == '"') {
                if (quoted and std.mem.endsWith(u8, line, "\";") and std.mem.find(u8, line, "->") == null) try ids.append(a, line[start..i]);
                quoted = !quoted;
                start = i + 1;
            }
        }
        try expect(!quoted);
    }
    try eq(hostile.len, ids.items.len);
    for (ids.items, 0..) |x, i| for (ids.items[i + 1 ..]) |y| try expect(!std.mem.eql(u8, x, y));
}

test "hostile paths: mermaid labels hold no quote and json and sarif read back as the paths" {
    var graph = try hostileGraph();
    defer graph.deinit();
    const m = try drawn(report.mermaid, &graph, .{});
    defer a.free(m);
    var lines = std.mem.splitScalar(u8, m, '\n');
    while (lines.next()) |line| try expect(std.mem.count(u8, line, "\"") % 2 == 0 and std.mem.count(u8, line, "\"") <= 2);

    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try report.json(&out.writer, &graph, &.{});
    const parsed = try std.json.parseFromSlice(std.json.Value, a, out.written(), .{});
    defer parsed.deinit();
    const nodes = parsed.value.object.get("nodes").?.array.items;
    try eq(hostile.len, nodes.len);
    for (hostile, nodes) |p, node| {
        const read = node.object.get("path").?.string;
        if (std.unicode.utf8ValidateSlice(p)) try std.testing.expectEqualStrings(p, read) else try std.testing.expectEqualStrings("bad\u{fffd}byte.zig", read);
    }

    // Every byte of a path survives a SARIF URI.
    const violations = try a.alloc(g.rules.Violation, hostile.len);
    defer a.free(violations);
    for (hostile, violations) |p, *v| v.* = .{ .rule = "r", .reason = .unreached, .path = p };
    out.clearRetainingCapacity();
    try report.sarif(a, &out.writer, violations, .{});
    const log = try std.json.parseFromSlice(std.json.Value, a, out.written(), .{});
    defer log.deinit();
    const results = log.value.object.get("runs").?.array.items[0].object.get("results").?.array.items;
    for (hostile, results) |p, result| {
        const uri = result.object.get("locations").?.array.items[0].object.get("physicalLocation").?.object.get("artifactLocation").?.object.get("uri").?.string;
        var decoded: std.ArrayList(u8) = .empty;
        defer decoded.deinit(a);
        var i: usize = 0;
        while (i < uri.len) : (i += 1) {
            if (uri[i] == '%') {
                try decoded.append(a, try std.fmt.parseInt(u8, uri[i + 1 .. i + 3], 16));
                i += 2;
            } else try decoded.append(a, uri[i]);
        }
        try std.testing.expectEqualStrings(p, decoded.items);
    }
}

test "reports are the same for the same graph whatever the input edge order" {
    var reversed: [edges.len]g.Edge = undefined;
    for (edges, 0..) |e, i| reversed[edges.len - 1 - i] = e;
    var one = try g.Graph.fromEdges(a, paths, edges);
    defer one.deinit();
    var two = try g.Graph.fromEdges(a, paths, &reversed);
    defer two.deinit();
    inline for (.{ report.dot, report.mermaid }) |draw| {
        const x = try drawn(draw, &one, .{ .cluster = .directory });
        defer a.free(x);
        const y = try drawn(draw, &two, .{ .cluster = .directory });
        defer a.free(y);
        try std.testing.expectEqualStrings(x, y);
    }
}

test "empty graph and no findings give well-formed reports" {
    var graph = try g.Graph.fromEdges(a, &.{}, &.{});
    defer graph.deinit();
    const d = try drawn(report.dot, &graph, .{ .cluster = .directory });
    defer a.free(d);
    try std.testing.expectEqualStrings("digraph \"gantry\" {\n  rankdir=LR;\n  node [shape=box, style=rounded];\n}\n", d);
    const m = try drawn(report.mermaid, &graph, .{ .cluster = .layer, .layers = layers });
    defer a.free(m);
    try std.testing.expectEqualStrings("flowchart LR\n", m);
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try report.json(&out.writer, &graph, &.{});
    const parsed = try std.json.parseFromSlice(std.json.Value, a, out.written(), .{});
    parsed.deinit();
    out.clearRetainingCapacity();
    try report.sarif(a, &out.writer, &.{}, .{});
    const log = try std.json.parseFromSlice(std.json.Value, a, out.written(), .{});
    log.deinit();
}

test "reports release everything when an allocation fails" {
    var graph = try g.Graph.fromEdges(a, paths, edges);
    defer graph.deinit();
    var findings_owned = try graph.check(a, rules);
    defer findings_owned.deinit();
    const findings = findings_owned.items();
    try std.testing.checkAllAllocationFailures(a, struct {
        fn run(gpa: std.mem.Allocator, graph_: *const g.Graph, findings_: []const g.rules.Violation) !void {
            var buffer: [16 * 1024]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buffer);
            try report.dot(gpa, &w, graph_, .{ .cluster = .layer, .layers = layers, .findings = findings_ });
            w = .fixed(&buffer);
            try report.mermaid(gpa, &w, graph_, .{ .cluster = .directory, .findings = findings_ });
            w = .fixed(&buffer);
            try report.sarif(gpa, &w, findings_, .{});
        }
    }.run, .{ &graph, findings });
}
