const std = @import("std");
const g = @import("gantry.zig");
const f = @import("testing/test_support.zig");
const a = std.testing.allocator;

fn failed(diagnostic: *const g.ScanDiagnostic, path: ?[]const u8, phase: g.ScanDiagnostic.Phase, cause: anyerror) !void {
    const failure = diagnostic.failure orelse return error.TestExpectedDiagnostic;
    try std.testing.expectEqual(phase, failure.phase);
    try std.testing.expectEqual(cause, failure.cause);
    try std.testing.expectEqual(null, failure.offset);
    if (path) |p| try std.testing.expectEqualStrings(p, failure.path.?) else try std.testing.expectEqual(null, failure.path);
}

const Reader = struct {
    fail_on: usize = 1,
    calls: usize = 0,
    fn read(self: *@This(), _: []const u8, _: std.mem.Allocator) !?[]const u8 {
        self.calls += 1;
        if (self.calls == self.fail_on) return error.ReaderRefused;
        return "";
    }
};

test "scan diagnostics retain reader causes through every read pass" {
    var diagnostic = g.ScanDiagnostic.init(a);
    defer diagnostic.deinit();
    for ([_]struct { path: []const u8, pass: usize = 1 }{
        .{ .path = "src/a.zig" },
        .{ .path = "src/a.go" },
        .{ .path = "go.mod" },
        .{ .path = "go.work" },
        .{ .path = "package.json" },
        .{ .path = "tsconfig.json" },
        .{ .path = "src/a.rs" },
        .{ .path = "pkg/a.py" },
    }) |case| {
        var reader: Reader = .{ .fail_on = case.pass };
        try std.testing.expectError(error.ReaderRefused, g.scanWithDiagnostic(a, &.{case.path}, &reader, Reader.read, .{}, &diagnostic));
        try failed(&diagnostic, case.path, .read, error.ReaderRefused);
    }
}

test "scan diagnostics identify invalid paths manifests and Go constraints" {
    var diagnostic = g.ScanDiagnostic.init(a);
    defer diagnostic.deinit();
    const empty: f.Fixture = .{ .items = &.{} };
    try std.testing.expectError(error.InvalidPath, g.scanWithDiagnostic(a, &.{ "ok.zig", "../outside.zig" }, empty, f.Fixture.read, .{}, &diagnostic));
    try failed(&diagnostic, "../outside.zig", .paths, error.InvalidPath);
    const manifest: f.Fixture = .{ .items = &.{.{ .path = "sub/build.zig.zon", .text = ".{ .dependencies = .{ .x = .{ .path = \"x\" } }, .tail = }" }} };
    try std.testing.expectError(error.InvalidManifest, g.scanWithDiagnostic(a, &.{ "sub/build.zig.zon", "a.zig", "b.zig" }, manifest, f.Fixture.read, .{}, &diagnostic));
    try failed(&diagnostic, "sub/build.zig.zon", .manifests, error.InvalidManifest);
    const go: f.Fixture = .{ .items = &.{.{ .path = "src/a.go", .text = "//go:build linux &&\n\npackage a" }} };
    try std.testing.expectError(error.InvalidBuildConstraint, g.scanWithDiagnostic(a, &.{"src/a.go"}, go, f.Fixture.read, .{ .go_target = .{ .os = "linux", .arch = "amd64" } }, &diagnostic));
    try failed(&diagnostic, "src/a.go", .go_constraints, error.InvalidBuildConstraint);
}

test "scan diagnostics identify extended config parsing and inheritance failures" {
    var diagnostic = g.ScanDiagnostic.init(a);
    defer diagnostic.deinit();
    for ([_][]const u8{ "[]", "{\"compilerOptions\":{\"paths\":{\"x\":\"bad\"}}}" }) |text| {
        const fixture: f.Fixture = .{ .items = &.{
            .{ .path = "pkg/tsconfig.json", .text = "{\"extends\":\"./base.json\"}" },
            .{ .path = "pkg/base.json", .text = text },
            .{ .path = "other/tsconfig.json", .text = "{}" },
        } };
        try std.testing.expectError(error.InvalidConfig, g.scanWithDiagnostic(a, &.{ "pkg/tsconfig.json", "pkg/base.json", "other/tsconfig.json" }, fixture, f.Fixture.read, .{}, &diagnostic));
        try failed(&diagnostic, "pkg/base.json", .configs, error.InvalidConfig);
    }
    const unread: f.Fixture = .{ .items = &.{.{ .path = "tsconfig.json", .text = "{\"extends\":\"./base.json\"}" }} };
    try std.testing.expectError(error.MissingFixture, g.scanWithDiagnostic(a, &.{ "tsconfig.json", "base.json" }, unread, f.Fixture.read, .{}, &diagnostic));
    try failed(&diagnostic, "base.json", .read, error.MissingFixture);
    const cycle: f.Fixture = .{ .items = &.{
        .{ .path = "a/tsconfig.json", .text = "{\"extends\":\"../cycle/one.json\"}" },
        .{ .path = "cycle/one.json", .text = "{\"extends\":\"./two.json\"}" },
        .{ .path = "cycle/two.json", .text = "{\"extends\":\"./one.json\"}" },
    } };
    try std.testing.expectError(error.ConfigCycle, g.scanWithDiagnostic(a, &.{ "a/tsconfig.json", "cycle/one.json", "cycle/two.json" }, cycle, f.Fixture.read, .{}, &diagnostic));
    try std.testing.expectEqual(g.ScanDiagnostic.Phase.configs, diagnostic.failure.?.phase);
    try std.testing.expectEqual(error.ConfigCycle, diagnostic.failure.?.cause);
    const p = diagnostic.failure.?.path.?;
    try std.testing.expect(std.mem.eql(u8, p, "cycle/one.json") or std.mem.eql(u8, p, "cycle/two.json"));
}

test "scan diagnostics distinguish import and preprocessing errors from reads" {
    var diagnostic = g.ScanDiagnostic.init(a);
    defer diagnostic.deinit();
    for ([_]struct { path: []const u8, text: []const u8, phase: g.ScanDiagnostic.Phase, cause: anyerror }{
        .{ .path = "src/a.zig", .text = "const b = @import(\"\\q\");", .phase = .imports, .cause = error.InvalidLiteral },
        .{ .path = "src/a.js", .text = "import '\\x';", .phase = .imports, .cause = error.InvalidEscape },
        .{ .path = "pkg/api.py", .text = "__all__ = ['\\q']", .phase = .python_exports, .cause = error.InvalidEscape },
        .{ .path = "pkg/tsconfig.json", .text = "{} /* unfinished", .phase = .configs, .cause = error.SyntaxError },
    }) |case| {
        const fixture: f.Fixture = .{ .items = &.{.{ .path = case.path, .text = case.text }} };
        try std.testing.expectError(case.cause, g.scanWithDiagnostic(a, &.{case.path}, fixture, f.Fixture.read, .{}, &diagnostic));
        try failed(&diagnostic, case.path, case.phase, case.cause);
    }
}

test "scan diagnostics own paths after cleanup and reset on every call" {
    var diagnostic = g.ScanDiagnostic.init(a);
    defer diagnostic.deinit();
    {
        var inputs: std.heap.ArenaAllocator = .init(a);
        defer inputs.deinit();
        const raw = try inputs.allocator().dupe(u8, "src/./a.zig");
        try std.testing.expectError(error.MissingFixture, g.scanWithDiagnostic(a, &.{raw}, f.Fixture{ .items = &.{} }, f.Fixture.read, .{}, &diagnostic));
        @memset(raw, 'x');
    }
    try failed(&diagnostic, "src/a.zig", .read, error.MissingFixture);
    const fixture: f.Fixture = .{ .items = &.{
        .{ .path = "a.zig", .text = "const b = @import(\"b.zig\");" },
        .{ .path = "b.zig" },
        .{ .path = "pkg/__init__.py", .text = null },
    } };
    var graph = try g.scanWithDiagnostic(a, &.{ "a.zig", "b.zig", "pkg/__init__.py" }, fixture, f.Fixture.read, .{}, &diagnostic);
    defer graph.deinit();
    try std.testing.expectEqual(null, diagnostic.failure);
    try f.edge(&graph, "a.zig", "b.zig", .import, 1);
    try std.testing.expectEqualDeep(&[_][]const u8{"pkg/__init__.py"}, graph.unread());
    var plain = try g.scan(a, &.{ "a.zig", "b.zig", "pkg/__init__.py" }, fixture, f.Fixture.read, .{});
    defer plain.deinit();
    try std.testing.expectEqualDeep(plain.edges(), graph.edges());
    try std.testing.expectEqualDeep(plain.unread(), graph.unread());
    try std.testing.expectError(error.InvalidPath, g.scanWithDiagnostic(a, &.{"../again"}, fixture, f.Fixture.read, .{}, &diagnostic));
    try failed(&diagnostic, "../again", .paths, error.InvalidPath);
    var empty = try g.scanWithDiagnostic(a, &.{}, fixture, f.Fixture.read, .{}, &diagnostic);
    defer empty.deinit();
    try std.testing.expectEqual(null, diagnostic.failure);
}

test "scan diagnostics preserve causes when copying the path runs out of memory" {
    var storage: [0]u8 = .{};
    var fixed: std.heap.FixedBufferAllocator = .init(&storage);
    var diagnostic = g.ScanDiagnostic.init(fixed.allocator());
    defer diagnostic.deinit();
    try std.testing.expectError(error.MissingFixture, g.scanWithDiagnostic(a, &.{"a.zig"}, f.Fixture{ .items = &.{} }, f.Fixture.read, .{}, &diagnostic));
    try failed(&diagnostic, null, .read, error.MissingFixture);
}

fn allocations(alloc: std.mem.Allocator, expected: ?*const g.Graph) !g.Graph {
    var diagnostic = g.ScanDiagnostic.init(a);
    defer diagnostic.deinit();
    const fixture: f.Fixture = .{ .items = &.{
        .{ .path = "a.go", .text = "package a" },
        .{ .path = "a.zig", .text = "const b = @import(\"b.zig\");" },
        .{ .path = "b.zig" },
        .{ .path = "package.json", .text = "{\"dependencies\":{\"dep\":\"1\"}}" },
        .{ .path = "tsconfig.json", .text = "{\"extends\":\"./base.json\"}" },
        .{ .path = "base.json", .text = "{\"compilerOptions\":{\"paths\":{\"alias\":[\"dep\"]}}}" },
        .{ .path = "a.rs", .text = "mod b;" },
        .{ .path = "b.rs" },
        .{ .path = "pkg/__init__.py", .text = "from .api import *" },
        .{ .path = "pkg/api.py", .text = "from .impl import Public\n__all__ = ['Public']" },
        .{ .path = "pkg/impl.py" },
        .{ .path = "note.md", .text = "[other](other.md)" },
        .{ .path = "other.md" },
        .{ .path = "index.html", .text = "<img src=\"pic.svg\">" },
        .{ .path = "pic.svg" },
    } };
    var paths: [fixture.items.len][]const u8 = undefined;
    for (fixture.items, &paths) |item, *p| p.* = item.path;
    var graph = g.scanWithDiagnostic(alloc, &paths, fixture, f.Fixture.read, .{ .kinds = &.{ .import, .@"test", .link, .asset } }, &diagnostic) catch |cause| {
        try std.testing.expectEqual(error.OutOfMemory, cause);
        try std.testing.expectEqual(cause, diagnostic.failure.?.cause);
        if (diagnostic.failure.?.phase == .graph) try std.testing.expectEqual(null, diagnostic.failure.?.path);
        return cause;
    };
    errdefer graph.deinit();
    try std.testing.expectEqual(null, diagnostic.failure);
    if (expected) |full| {
        try std.testing.expectEqualDeep(full.paths(), graph.paths());
        try std.testing.expectEqualDeep(full.edges(), graph.edges());
        try std.testing.expectEqualDeep(full.references(), graph.references());
        try std.testing.expectEqualDeep(full.dependencies(), graph.dependencies());
        try std.testing.expectEqualDeep(full.goFiles(), graph.goFiles());
        try std.testing.expectEqualDeep(full.unread(), graph.unread());
    }
    return graph;
}

test "scan diagnostics release every allocation failure without exposing a partial graph" {
    var count = std.testing.FailingAllocator.init(a, .{});
    var full = try allocations(count.allocator(), null);
    defer full.deinit();
    for (0..count.alloc_index) |n| {
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = n });
        if (allocations(failing.allocator(), &full)) |value| {
            // Arena.reset may fail its optional preallocation and still leave
            // a fully working arena. That success must return the whole graph.
            var graph = value;
            graph.deinit();
        } else |cause| try std.testing.expectEqual(error.OutOfMemory, cause);
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}
