const std = @import("std");
const g = @import("../gantry.zig");
const f = @import("../testing/support.zig");
const a = std.testing.allocator;

fn failed(diagnostic: *const g.Diagnostics, path: ?[]const u8, phase: g.Diagnostics.Phase, cause: anyerror) !void {
    const failure = diagnostic.failure orelse return error.TestExpectedDiagnostic;
    try std.testing.expectEqual(phase, failure.phase);
    try std.testing.expectEqual(cause, failure.cause);
    try std.testing.expectEqual(null, failure.offset);
    if (path) |p| try std.testing.expectEqualStrings(p, failure.path.?) else try std.testing.expectEqual(null, failure.path);
}

const Reader = struct {
    fail_on: usize = 1,
    calls: usize = 0,
    fn read(_: std.mem.Allocator, _: std.Io, self: *Reader, _: []const u8) !?[]const u8 {
        self.calls += 1;
        if (self.calls == self.fail_on) return error.ReaderRefused;
        return "";
    }
};

test "scan diagnostics retain reader causes through every read pass" {
    var diagnostic = g.Diagnostics.init(a);
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
        try std.testing.expectError(error.ReaderRefused, g.scan(a, std.testing.io, &.{case.path}, &reader, Reader.read, .{ .diagnostics = &diagnostic }));
        try failed(&diagnostic, case.path, .read, error.ReaderRefused);
    }
}

/// The scan succeeds, `path` is its one invalid file, for `cause` in `phase`.
fn invalid(graph: *const g.Graph, path: []const u8, phase: g.Diagnostics.Phase, cause: g.FileError) !void {
    try std.testing.expectEqual(1, graph.invalid().len);
    const record = graph.invalid()[0];
    try std.testing.expectEqualStrings(path, record.path);
    try std.testing.expectEqual(phase, record.phase);
    try std.testing.expectEqual(cause, record.cause);
}

test "scan diagnostics identify invalid paths; invalid manifests and Go constraints are records" {
    var diagnostic = g.Diagnostics.init(a);
    defer diagnostic.deinit();
    const empty: f.Fixture = .{ .items = &.{} };
    try std.testing.expectError(error.InvalidPath, g.scan(a, std.testing.io, &.{ "ok.zig", "../outside.zig" }, empty, f.Fixture.read, .{ .diagnostics = &diagnostic }));
    try failed(&diagnostic, "../outside.zig", .paths, error.InvalidPath);
    const manifest: f.Fixture = .{ .items = &.{
        .{ .path = "sub/build.zig.zon", .text = ".{ .dependencies = .{ .x = .{ .path = \"x\" } }, .tail = }" },
        .{ .path = "a.zig", .text = "const b = @import(\"b.zig\");" },
        .{ .path = "b.zig" },
        .{ .path = "package.json", .text = "{\"dependencies\":{\"kept\":\"1\"}}" },
    } };
    var declared = try g.scan(a, std.testing.io, &.{ "sub/build.zig.zon", "a.zig", "b.zig", "package.json" }, manifest, f.Fixture.read, .{ .diagnostics = &diagnostic });
    defer declared.deinit();
    try std.testing.expectEqual(null, diagnostic.failure);
    try invalid(&declared, "sub/build.zig.zon", .manifests, error.InvalidManifest);
    try f.edge(&declared, "a.zig", "b.zig", .import, 1);
    try std.testing.expectEqual(1, declared.dependencies().len);
    // Go leaves a file whose constraint it cannot read out of its package.
    const go: f.Fixture = .{ .items = &.{
        .{ .path = "src/a.go", .text = "//go:build linux &&\n\npackage a\nimport \"example.com/m/b\"\n" },
        .{ .path = "src/c.go", .text = "package a\nimport \"example.com/m/b\"\n" },
        .{ .path = "go.mod", .text = "module example.com/m\n" },
        .{ .path = "b/b.go", .text = "package b\n" },
    } };
    var constrained = try g.scan(a, std.testing.io, &.{ "src/a.go", "src/c.go", "go.mod", "b/b.go" }, go, f.Fixture.read, .{ .go_target = .{ .os = "linux", .arch = "amd64" }, .diagnostics = &diagnostic });
    defer constrained.deinit();
    try invalid(&constrained, "src/a.go", .go_constraints, error.InvalidBuildConstraint);
    try std.testing.expectEqual(2, constrained.goFiles().len);
    try std.testing.expectEqual(1, constrained.edges().len);
    try f.edge(&constrained, "src/c.go", "b/b.go", .import, 1);
}

test "scan diagnostics record extended config parsing and inheritance failures" {
    var diagnostic = g.Diagnostics.init(a);
    defer diagnostic.deinit();
    for ([_][]const u8{ "[]", "{\"compilerOptions\":{\"paths\":{\"x\":\"bad\"}}}" }) |text| {
        // The broken base gives nothing; the config extending it keeps its own options.
        const fixture: f.Fixture = .{ .items = &.{
            .{ .path = "pkg/tsconfig.json", .text = "{\"extends\":\"./base.json\",\"compilerOptions\":{\"paths\":{\"@/*\":[\"src/*\"]}}}" },
            .{ .path = "pkg/base.json", .text = text },
            .{ .path = "pkg/a.ts", .text = "import '@/b';" },
            .{ .path = "pkg/src/b.ts" },
        } };
        var graph = try g.scan(a, std.testing.io, &.{ "pkg/tsconfig.json", "pkg/base.json", "pkg/a.ts", "pkg/src/b.ts" }, fixture, f.Fixture.read, .{ .diagnostics = &diagnostic });
        defer graph.deinit();
        try invalid(&graph, "pkg/base.json", .configs, error.InvalidConfig);
        try f.edge(&graph, "pkg/a.ts", "pkg/src/b.ts", .import, 1);
    }
    const unread: f.Fixture = .{ .items = &.{.{ .path = "tsconfig.json", .text = "{\"extends\":\"./base.json\"}" }} };
    try std.testing.expectError(error.MissingFixture, g.scan(a, std.testing.io, &.{ "tsconfig.json", "base.json" }, unread, f.Fixture.read, .{ .diagnostics = &diagnostic }));
    try failed(&diagnostic, "base.json", .read, error.MissingFixture);
    const cycle: f.Fixture = .{ .items = &.{
        .{ .path = "a/tsconfig.json", .text = "{\"extends\":\"../cycle/one.json\"}" },
        .{ .path = "cycle/one.json", .text = "{\"extends\":\"./two.json\"}" },
        .{ .path = "cycle/two.json", .text = "{\"extends\":\"./one.json\"}" },
    } };
    var cyclic = try g.scan(a, std.testing.io, &.{ "a/tsconfig.json", "cycle/one.json", "cycle/two.json" }, cycle, f.Fixture.read, .{ .diagnostics = &diagnostic });
    defer cyclic.deinit();
    try std.testing.expectEqual(1, cyclic.invalid().len);
    const record = cyclic.invalid()[0];
    try std.testing.expectEqual(g.Diagnostics.Phase.configs, record.phase);
    try std.testing.expectEqual(error.ConfigCycle, record.cause);
    try std.testing.expect(std.mem.eql(u8, record.path, "cycle/one.json") or std.mem.eql(u8, record.path, "cycle/two.json"));
}

test "scan diagnostics record import and preprocessing errors and keep reading other files" {
    var diagnostic = g.Diagnostics.init(a);
    defer diagnostic.deinit();
    for ([_]struct { path: []const u8, text: []const u8, phase: g.Diagnostics.Phase, cause: g.FileError }{
        .{ .path = "src/a.zig", .text = "const b = @import(\"\\q\");", .phase = .imports, .cause = error.InvalidLiteral },
        .{ .path = "src/a.js", .text = "import '\\x';", .phase = .imports, .cause = error.InvalidEscape },
        .{ .path = "testdata/bad.go", .text = "package bad\nimport \"\\q\"\n", .phase = .imports, .cause = error.InvalidEscape },
        .{ .path = "pkg/api.py", .text = "__all__ = ['\\q']", .phase = .python_exports, .cause = error.InvalidEscape },
        .{ .path = "pkg/tsconfig.json", .text = "{} /* unfinished", .phase = .configs, .cause = error.SyntaxError },
        .{ .path = "vendor/x/tsconfig.json", .text = "not json", .phase = .configs, .cause = error.SyntaxError },
        .{ .path = "x.nimble", .text = "requires \"\"", .phase = .manifests, .cause = error.InvalidManifest },
        .{ .path = "go.mod", .text = "module m\nrequire (\nx v1\n", .phase = .manifests, .cause = error.InvalidManifest },
    }) |case| {
        const fixture: f.Fixture = .{ .items = &.{
            .{ .path = case.path, .text = case.text },
            .{ .path = "z/a.zig", .text = "const b = @import(\"b.zig\");" },
            .{ .path = "z/b.zig" },
        } };
        var graph = try g.scan(a, std.testing.io, &.{ case.path, "z/a.zig", "z/b.zig" }, fixture, f.Fixture.read, .{ .python_star_reexports = true, .diagnostics = &diagnostic });
        defer graph.deinit();
        try std.testing.expectEqual(null, diagnostic.failure);
        try invalid(&graph, case.path, case.phase, case.cause);
        try f.edge(&graph, "z/a.zig", "z/b.zig", .import, 1);
    }
}

test "a leading byte order mark is no part of a file" {
    const bom = "\xEF\xBB\xBF";
    var graph = try (f.Fixture{ .items = &.{
        .{ .path = "tsconfig.json", .text = bom ++ "{\"compilerOptions\":{\"paths\":{\"@/*\":[\"src/*\"]}}}" },
        .{ .path = "package.json", .text = bom ++ "{\"dependencies\":{\"left-pad\":\"1\"}}" },
        .{ .path = "Cargo.toml", .text = bom ++ "[dependencies]\nserde = \"1\"\n" },
        .{ .path = "a.ts", .text = bom ++ "import '@/b';" },
        .{ .path = "src/b.ts" },
        .{ .path = "a.go", .text = bom ++ "//go:build windows\n\npackage a\n" },
    } }).scan(a, .{ .go_target = .{ .os = "linux", .arch = "amd64" } });
    defer graph.deinit();
    try std.testing.expectEqual(0, graph.invalid().len);
    try f.edge(&graph, "a.ts", "src/b.ts", .import, 1);
    try std.testing.expectEqual(2, graph.dependencies().len);
    try std.testing.expectEqual(false, graph.goFiles()[0].selected);
}

test "scan diagnostics own paths after cleanup and reset on every call" {
    var diagnostic = g.Diagnostics.init(a);
    defer diagnostic.deinit();
    {
        var inputs: std.heap.ArenaAllocator = .init(a);
        defer inputs.deinit();
        const raw = try inputs.allocator().dupe(u8, "src/./a.zig");
        try std.testing.expectError(error.MissingFixture, g.scan(a, std.testing.io, &.{raw}, f.Fixture{ .items = &.{} }, f.Fixture.read, .{ .diagnostics = &diagnostic }));
        @memset(raw, 'x');
    }
    try failed(&diagnostic, "src/a.zig", .read, error.MissingFixture);
    const fixture: f.Fixture = .{ .items = &.{
        .{ .path = "a.zig", .text = "const b = @import(\"b.zig\");" },
        .{ .path = "b.zig" },
        .{ .path = "pkg/__init__.py", .text = null },
    } };
    var graph = try g.scan(a, std.testing.io, &.{ "a.zig", "b.zig", "pkg/__init__.py" }, fixture, f.Fixture.read, .{ .diagnostics = &diagnostic });
    defer graph.deinit();
    try std.testing.expectEqual(null, diagnostic.failure);
    try f.edge(&graph, "a.zig", "b.zig", .import, 1);
    try std.testing.expectEqualDeep(&[_][]const u8{"pkg/__init__.py"}, graph.unread());
    var plain = try g.scan(a, std.testing.io, &.{ "a.zig", "b.zig", "pkg/__init__.py" }, fixture, f.Fixture.read, .{});
    defer plain.deinit();
    try std.testing.expectEqualDeep(plain.edges(), graph.edges());
    try std.testing.expectEqualDeep(plain.unread(), graph.unread());
    try std.testing.expectError(error.InvalidPath, g.scan(a, std.testing.io, &.{"../again"}, fixture, f.Fixture.read, .{ .diagnostics = &diagnostic }));
    try failed(&diagnostic, "../again", .paths, error.InvalidPath);
    var empty = try g.scan(a, std.testing.io, &.{}, fixture, f.Fixture.read, .{ .diagnostics = &diagnostic });
    defer empty.deinit();
    try std.testing.expectEqual(null, diagnostic.failure);
}

test "scan diagnostics preserve causes when copying the path runs out of memory" {
    var storage: [0]u8 = .{};
    var fixed: std.heap.FixedBufferAllocator = .init(&storage);
    var diagnostic = g.Diagnostics.init(fixed.allocator());
    defer diagnostic.deinit();
    try std.testing.expectError(error.MissingFixture, g.scan(a, std.testing.io, &.{"a.zig"}, f.Fixture{ .items = &.{} }, f.Fixture.read, .{ .diagnostics = &diagnostic }));
    try failed(&diagnostic, null, .read, error.MissingFixture);
}

fn allocations(alloc: std.mem.Allocator, expected: ?*const g.Graph) !g.Graph {
    var diagnostic = g.Diagnostics.init(a);
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
        .{ .path = "bad/tsconfig.json", .text = "not json" },
        .{ .path = "bad/a.zig", .text = "const b = @import(\"\\q\");" },
    } };
    var paths: [fixture.items.len][]const u8 = undefined;
    for (fixture.items, &paths) |item, *p| p.* = item.path;
    var graph = g.scan(alloc, std.testing.io, &paths, fixture, f.Fixture.read, .{ .kinds = &.{ .import, .@"test", .link, .asset }, .diagnostics = &diagnostic }) catch |cause| {
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
        try std.testing.expectEqualDeep(full.invalid(), graph.invalid());
    } else try std.testing.expectEqual(2, graph.invalid().len);
    return graph;
}

test "scan diagnostics release every allocation failure without exposing a partial graph" {
    // Refusing in-place resizes, as `f.steady` does, so every run allocates alike.
    var count = std.testing.FailingAllocator.init(a, .{ .resize_fail_index = 0 });
    var full = try allocations(count.allocator(), null);
    defer full.deinit();
    for (0..count.alloc_index) |n| {
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = n, .resize_fail_index = 0 });
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
