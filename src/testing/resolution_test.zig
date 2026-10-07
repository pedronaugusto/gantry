const std = @import("std");
const g = @import("../gantry.zig");
const f = @import("support.zig");
const a = std.testing.allocator;
const expect = std.testing.expect;
const eq = std.testing.expectEqual;
test "fixture: import fixtures resolve file edges in all six languages" {
    var graph = try (f.Fixture{ .items = &.{
        .{ .path = "src/a.zig", .text = "const std = @import(\"std\"); const b = @import(\"b.zig\"); const u = @import(\"../lib/util.zig\");" },
        .{ .path = "src/b.zig" },
        .{ .path = "lib/util.zig" },
        .{ .path = "c/main.c", .text = "#include <stdio.h>\n#include \"../inc/x.h\"" },
        .{ .path = "inc/x.h" },
        .{ .path = "web/app.ts", .text = "import { x } from './lib/x'; import react from 'react'; const y = require(\"./y\");" },
        .{ .path = "web/lib/x.ts" },
        .{ .path = "web/y/index.ts" },
        .{ .path = "py/pkg/__init__.py" },
        .{ .path = "py/pkg/m.py", .text = "from . import helper\nimport os\nfrom py.pkg.helper import f\n" },
        .{ .path = "py/pkg/helper.py" },
        .{ .path = "go/go.mod", .text = "module example.com/x/go" },
        .{ .path = "go/cmd/main.go", .text = "package main\nimport (\n\"fmt\"\n\"example.com/x/go/internal/db\"\n)" },
        .{ .path = "go/internal/db/db.go" },
        .{ .path = "rs/src/main.rs", .text = "mod net;\nuse crate::util::thing;" },
        .{ .path = "rs/src/net/mod.rs" },
        .{ .path = "rs/src/util.rs" },
    } }).scan(a, .{});
    defer graph.deinit();
    try f.edge(&graph, "src/a.zig", "src/b.zig", .import, 1);
    try f.edge(&graph, "src/a.zig", "lib/util.zig", .import, 1);
    try f.edge(&graph, "c/main.c", "inc/x.h", .import, 1);
    try f.edge(&graph, "web/app.ts", "web/lib/x.ts", .import, 1);
    try f.edge(&graph, "web/app.ts", "web/y/index.ts", .import, 1);
    try f.edge(&graph, "py/pkg/m.py", "py/pkg/helper.py", .import, 2);
    try f.edge(&graph, "py/pkg/m.py", "py/pkg/__init__.py", .import, 2);
    try f.edge(&graph, "go/cmd/main.go", "go/internal/db/db.go", .import, 1);
    try f.edge(&graph, "rs/src/main.rs", "rs/src/net/mod.rs", .import, 1);
    try f.edge(&graph, "rs/src/main.rs", "rs/src/util.rs", .import, 1);
    try eq(10, graph.edges().len);
    var dirs = try graph.aggregate(a, 99);
    defer dirs.deinit();
    try f.edge(&dirs, "py/pkg", "py/pkg", .import, 4);
}
test "Zig named modules are scoped to the importing tree" {
    var graph = try (f.Fixture{ .items = &.{
        .{ .path = "daemon/a.zig", .text = "const p = @import(\"proto\"); const m = p.mirror;" },
        .{ .path = "client/a.zig", .text = "const p = @import(\"proto\");" },
        .{ .path = "proto/root.zig" },
    } }).scan(a, .{ .named_modules = &.{.{ .name = "proto", .path = "proto/root.zig", .from = "daemon/**" }} });
    defer graph.deinit();
    try eq(1, graph.edges().len);
    try f.edge(&graph, "daemon/a.zig", "proto/root.zig", .import, 1);
    try expect(!graph.references()[0].resolved);
    try expect(graph.references()[1].resolved);
    try expect(graph.references()[2].member != null);
}
test "C include roots order and traversal" {
    var graph = try (f.Fixture{ .items = &.{
        .{ .path = "src/a.c", .text = "#include <x.h>\n#include \"../local.h\"\n#include \"../../escape.h\"" },
        .{ .path = "first/x.h" },
        .{ .path = "second/x.h" },
        .{ .path = "local.h" },
    } }).scan(a, .{ .include_roots = &.{ "first", "second" } });
    defer graph.deinit();
    try eq(2, graph.edges().len);
    try f.edge(&graph, "src/a.c", "first/x.h", .import, 1);
    try f.edge(&graph, "src/a.c", "local.h", .import, 1);
}
test "JS resolution extensions directory index emitted TS paths and packages" {
    var graph = try (f.Fixture{ .items = &.{
        .{ .path = "app.ts", .text = "import './a'; import './b.js'; import './dir'; import 'pkg'; import '/abs';" },
        .{ .path = "a.ts" },
        .{ .path = "a.js" },
        .{ .path = "b.ts" },
        .{ .path = "dir/index.cts" },
        .{ .path = "dir/index.js" },
        .{ .path = "pkg.ts" },
    } }).scan(a, .{});
    defer graph.deinit();
    try eq(3, graph.edges().len);
    try f.edge(&graph, "app.ts", "a.ts", .import, 1);
    try f.edge(&graph, "app.ts", "b.ts", .import, 1);
    try f.edge(&graph, "app.ts", "dir/index.js", .import, 1);
}
test "Python source roots relative parents and package initializer dependencies" {
    var graph = try (f.Fixture{ .items = &.{
        .{ .path = "src/pkg/child/main.py", .text = "import pkg.util\nfrom .. import util\nfrom . import helper\nfrom .... import outside" },
        .{ .path = "src/pkg/__init__.py" },
        .{ .path = "src/pkg/child/__init__.py" },
        .{ .path = "src/pkg/child/helper.py" },
        .{ .path = "src/pkg/util.py" },
        .{ .path = "outside.py" },
    } }).scan(a, .{ .python_roots = &.{"src"} });
    defer graph.deinit();
    try f.edge(&graph, "src/pkg/child/main.py", "src/pkg/util.py", .import, 2);
    try f.edge(&graph, "src/pkg/child/main.py", "src/pkg/__init__.py", .import, 2);
    try f.edge(&graph, "src/pkg/child/main.py", "src/pkg/child/__init__.py", .import, 1);
    try f.edge(&graph, "src/pkg/child/main.py", "src/pkg/child/helper.py", .import, 1);
    try eq(4, graph.edges().len);
}
test "Go uses declared module identity all selected package files and nested boundaries" {
    var graph = try (f.Fixture{ .items = &.{
        .{ .path = "go.mod", .text = "module example.com/x" },
        .{ .path = "cmd/a.go", .text = "import (\"example.com/x/pkg\"\n\"other.com/x/pkg\"\n\"example.com/xy/pkg\"\n\"example.com/x/sub/pkg\")" },
        .{ .path = "pkg/a.go" },
        .{ .path = "pkg/b.go" },
        .{ .path = "pkg/a_test.go" },
        .{ .path = "sub/go.mod", .text = "module example.com/y" },
        .{ .path = "sub/main.go", .text = "import \"example.com/y/pkg\"" },
        .{ .path = "sub/pkg/a.go" },
    } }).scan(a, .{ .manifests = false });
    defer graph.deinit();
    try eq(4, graph.edges().len);
    try f.edge(&graph, "cmd/a.go", "pkg/a.go", .import, 1);
    try f.edge(&graph, "cmd/a.go", "pkg/b.go", .import, 1);
    try f.edge(&graph, "cmd/a.go", "pkg/a_test.go", .@"test", 1);
    try f.edge(&graph, "sub/main.go", "sub/pkg/a.go", .import, 1);
}
test "Go without go.mod does not guess by suffix" {
    var graph = try (f.Fixture{ .items = &.{ .{ .path = "main.go", .text = "import \"other.com/pkg\"" }, .{ .path = "pkg/a.go" } } }).scan(a, .{});
    defer graph.deinit();
    try eq(0, graph.edges().len);
}
test "Rust file modules directories super and use symbol suffixes" {
    var graph = try (f.Fixture{ .items = &.{
        .{ .path = "src/lib.rs", .text = "mod a; use crate::{a::child::Thing, util};" },
        .{ .path = "src/a.rs", .text = "mod child; use super::util::Thing;" },
        .{ .path = "src/a/child.rs", .text = "use super::sibling;" },
        .{ .path = "src/a/sibling.rs" },
        .{ .path = "src/util/mod.rs" },
    } }).scan(a, .{});
    defer graph.deinit();
    try eq(6, graph.edges().len);
    try f.edge(&graph, "src/lib.rs", "src/a.rs", .import, 1);
    try f.edge(&graph, "src/lib.rs", "src/a/child.rs", .import, 1);
    try f.edge(&graph, "src/lib.rs", "src/util/mod.rs", .import, 1);
    try f.edge(&graph, "src/a.rs", "src/a/child.rs", .import, 1);
    try f.edge(&graph, "src/a.rs", "src/util/mod.rs", .import, 1);
    try f.edge(&graph, "src/a/child.rs", "src/a/sibling.rs", .import, 1);
}
test "path normalization stays inside root and input aliases coalesce" {
    const norm = try g.path.normalize(a, "src/../lib/./x.zig");
    defer a.free(norm);
    try std.testing.expectEqualStrings("lib/x.zig", norm);
    for ([_][]const u8{ "../x", "/x", "C:/x", "c:x", "a\\b", "a/../../x" }) |p| try std.testing.expectError(error.InvalidPath, g.Graph.init(a, &.{p}));
    // A colon past a drive's place is a byte of the name.
    var colons = try g.scan(a, &.{ "docs/a:b.md", "ab:c", "a.zig" }, f.Fixture{ .items = &.{
        .{ .path = "docs/a:b.md", .text = "" },
        .{ .path = "ab:c", .text = "" },
        .{ .path = "a.zig", .text = "" },
    } }, f.Fixture.read, .{});
    colons.deinit();
    var graph = try g.Graph.init(a, &.{ "a.zig", "./a.zig", "x/../a.zig" });
    defer graph.deinit();
    try eq(1, graph.paths().len);
}
test "null reads are reported and errors do not return a partial graph" {
    var graph = try (f.Fixture{ .items = &.{ .{ .path = "a.zig", .text = null }, .{ .path = "package.json", .text = null }, .{ .path = "data.bin", .text = null } } }).scan(a, .{});
    defer graph.deinit();
    try eq(2, graph.unread().len);
    try std.testing.expectError(error.MissingFixture, g.scan(a, &.{"a.zig"}, f.Fixture{ .items = &.{} }, f.Fixture.read, .{}));
}
test "unread paths include every null read when manifest declarations are disabled" {
    var graph = try (f.Fixture{ .items = &.{
        .{ .path = "package.json", .text = null },
        .{ .path = "data.bin", .text = null },
        .{ .path = "main.go", .text = null },
        .{ .path = "pkg.py", .text = null },
        .{ .path = "src/lib.rs", .text = null },
    } }).scan(a, .{ .manifests = false, .kinds = &.{.asset} });
    defer graph.deinit();
    try std.testing.expectEqualDeep(&[_][]const u8{ "main.go", "package.json", "pkg.py", "src/lib.rs" }, graph.unread());
}
test "unread paths appear once across config and asset reads" {
    var graph = try (f.Fixture{ .items = &.{
        .{ .path = "tsconfig.json", .text = null },
        .{ .path = "go.mod", .text = null },
        .{ .path = "main.go", .text = null },
        .{ .path = "main.go", .text = null },
    } }).scan(a, .{ .kinds = &.{ .import, .asset } });
    defer graph.deinit();
    try std.testing.expectEqualDeep(&[_][]const u8{ "go.mod", "main.go", "tsconfig.json" }, graph.unread());
}
fn unreadAllocations(alloc: std.mem.Allocator) !void {
    var graph = try (f.Fixture{ .items = &.{
        .{ .path = "tsconfig.json", .text = null },
        .{ .path = "package.json", .text = null },
        .{ .path = "main.go", .text = null },
        .{ .path = "pkg.py", .text = null },
        .{ .path = "src/lib.rs", .text = null },
    } }).scan(alloc, .{ .kinds = &.{ .import, .asset } });
    defer graph.deinit();
    try eq(5, graph.unread().len);
}
test "unread paths release every failed allocation" {
    try f.checkAllAllocationFailures(unreadAllocations, .{});
}

const ScratchReader = struct {
    accounting: *std.testing.FailingAllocator,
    config: bool,
    calls: usize = 0,
    fn read(scratch: std.mem.Allocator, self: *ScratchReader, _: []const u8) !?[]const u8 {
        const retained = self.accounting.allocated_bytes - self.accounting.freed_bytes;
        // A 64 KiB read buffer must be reused rather than retaining one for
        // every file. Leave room for graph nodes and parser/index workspaces.
        if (retained > 512 * 1024) {
            std.debug.print("reader scratch retained {d} bytes before read\n", .{retained});
            return error.ScratchRetained;
        }
        const bytes = try scratch.alloc(u8, 64 * 1024);
        @memset(bytes, ' ');
        self.calls += 1;
        if (!self.config) return null;
        bytes[0] = '{';
        bytes[1] = '}';
        return bytes;
    }
};
fn boundedScratch(suffix: []const u8, config: bool) !void {
    var inputs: std.heap.ArenaAllocator = .init(a);
    defer inputs.deinit();
    var paths: [64][]const u8 = undefined;
    for (&paths, 0..) |*path, i| path.* = try inputs.allocator().print("{d}/{s}", .{ i, suffix });
    var accounting: std.testing.FailingAllocator = .init(a, .{});
    var reader: ScratchReader = .{ .accounting = &accounting, .config = config };
    {
        var graph = try g.scan(accounting.allocator(), &paths, &reader, ScratchReader.read, .{ .kinds = &.{} });
        defer graph.deinit();
        try eq(64, reader.calls);
        try eq(if (config) @as(usize, 0) else 64, graph.unread().len);
    }
    try eq(accounting.allocated_bytes, accounting.freed_bytes);
}
test "Rust preprocessing resets scratch even when the reader returns null" {
    try boundedScratch("lib.rs", false);
}
test "Python preprocessing resets scratch even when the reader returns null" {
    try boundedScratch("pkg.py", false);
}
test "config loading resets reader scratch between files" {
    try boundedScratch("tsconfig.json", true);
}

test "returned graphs release construction-only resolution storage" {
    const padding = try a.alloc(u8, 1024 * 1024);
    defer a.free(padding);
    @memset(padding, 'x');
    const config = try a.print("{{\"ignored\":\"{s}\",\"extends\":\"./base.json\",\"compilerOptions\":{{\"baseUrl\":\"src\"}}}}", .{padding});
    defer a.free(config);
    var accounting: std.testing.FailingAllocator = .init(a, .{});
    {
        var graph = try (f.Fixture{ .items = &.{
            .{ .path = "tsconfig.json", .text = config },
            .{ .path = "base.json", .text = null },
            .{ .path = "src/app.ts", .text = "import 'util';" },
            .{ .path = "src/util.ts" },
        } }).scan(accounting.allocator(), .{});
        defer graph.deinit();
        // The ignored config string is needed only during construction.
        // Returned nodes, edges, references and unread paths are much smaller.
        const retained = accounting.allocated_bytes - accounting.freed_bytes;
        if (retained > 512 * 1024) {
            std.debug.print("graph retained {d} bytes of construction storage\n", .{retained});
            return error.ConstructionStorageRetained;
        }
        try f.edge(&graph, "src/app.ts", "src/util.ts", .import, 1);
        try std.testing.expectEqualStrings("util", graph.references()[0].name);
        try std.testing.expectEqualDeep(&[_][]const u8{"base.json"}, graph.unread());
    }
    try eq(accounting.allocated_bytes, accounting.freed_bytes);
}

test "DirReader and walk use a temp directory and caller pruning" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.createDirPath(io, "ignored");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "const m = @import(\"model.zig\");" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/model.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "ignored/fake.zig", .data = "" });
    var paths = try g.walk(a, io, tmp.dir, {}, struct {
        fn keep(_: void, p: []const u8, _: std.Io.File.Kind) bool {
            return !g.path.within("ignored", p);
        }
    }.keep);
    defer paths.deinit();
    try eq(2, paths.items().len);
    var graph = try g.scan(a, paths.items(), g.DirReader{ .io = io, .dir = tmp.dir }, g.DirReader.read, .{});
    defer graph.deinit();
    try eq(1, graph.edges().len);
    try std.testing.expectError(error.StreamTooLong, g.scan(a, paths.items(), g.DirReader{ .io = io, .dir = tmp.dir, .limit = .limited(4) }, g.DirReader.read, .{}));
}
test "walk lists a colon in a name and skips what a scan would refuse" {
    // Windows file names hold neither byte.
    if (std.Io.Dir.path.sep == '\\') return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "docs");
    try tmp.dir.writeFile(io, .{ .sub_path = "docs/a:b.md", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "c:d.md", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "docs/x\\y.md", .data = "" });
    var paths = try g.walk(a, io, tmp.dir, {}, struct {
        fn keep(_: void, _: []const u8, _: std.Io.File.Kind) bool {
            return true;
        }
    }.keep);
    defer paths.deinit();
    try eq(1, paths.items().len);
    try std.testing.expectEqualStrings("docs/a:b.md", paths.items()[0]);
    var graph = try g.scan(a, paths.items(), g.DirReader{ .io = io, .dir = tmp.dir }, g.DirReader.read, .{});
    defer graph.deinit();
}

test "language extensions are explicit and unsupported files stay unread" {
    var buffer: [32]u8 = undefined;
    for ([_][]const u8{ ".zig", ".c", ".h", ".cc", ".cpp", ".cxx", ".hpp", ".hh", ".hxx", ".m", ".mm", ".js", ".mjs", ".cjs", ".jsx", ".ts", ".tsx", ".mts", ".cts", ".py", ".go", ".rs", ".nim", ".java" }) |ext| try expect(g.languageOf(try std.mem.print(&buffer, "file{s}", .{ext})) != null);
    try expect(g.languageOf(".zig") == null);
    try expect(g.languageOf("a.ZIG") == null);
    try expect(g.languageOf("a.kt") == null);
    try expect(g.languageOf("config.nims") == null);
    try expect(g.languageOf("a.php") == null);
    var graph = try g.scan(a, &.{"a.bin"}, f.Fixture{ .items = &.{} }, f.Fixture.read, .{});
    defer graph.deinit();
    try eq(1, graph.paths().len);
}

test "absolute references stay unresolved beside matching relative files" {
    var graph = try (f.Fixture{ .items = &.{
        .{ .path = "src/a.zig", .text = "const abs = @import(\"/b.zig\"); const rel = @import(\"b.zig\");" },
        .{ .path = "src/b.zig" },
        .{ .path = "c/main.c", .text = "#include \"/x.h\"\n#include \"x.h\"" },
        .{ .path = "c/x.h" },
    } }).scan(a, .{ .manifests = false });
    defer graph.deinit();
    for (graph.references()) |ref| if (ref.name[0] == '/') try expect(!ref.resolved);
    try f.edge(&graph, "src/a.zig", "src/b.zig", .import, 1);
    try f.edge(&graph, "c/main.c", "c/x.h", .import, 1);
    try eq(2, graph.edges().len);
}

fn reference(graph: *const g.Graph, from: []const u8, name: []const u8) !g.Reference {
    for (graph.references()) |ref| if (std.mem.eql(u8, ref.from, from) and std.mem.eql(u8, ref.name, name)) return ref;
    std.debug.print("missing reference {s} in {s}\n", .{ name, from });
    return error.TestExpectedReference;
}

test "Rust 2018 use paths name the current module's own modules first, as rustc resolves them" {
    // Each case was compiled with rustc 1.93 (edition 2021): the uniform
    // paths resolve to the declared modules, an outer module's `mod util`
    // is not in scope inside `mod inner` (there `util` is the extern
    // crate, or E0432 without one), and `extern crate util` beside
    // `mod util` is E0260.
    var graph = try (f.Fixture{ .items = &.{
        .{ .path = "src/lib.rs", .text =
        \\mod util;
        \\mod inline { pub struct I; }
        \\mod nested;
        \\use inline::I;
        \\use util::Thing;
        \\mod inner { use util::Other; }
        \\pub fn k() { use util::Body; }
        \\fn global() { use ::util::Global; }
        },
        .{ .path = "src/util.rs", .text = "pub struct Thing;" },
        .{ .path = "src/nested.rs", .text = "mod deep;\nuse deep::D;\n" },
        .{ .path = "src/nested/deep.rs", .text = "pub struct D;" },
        .{ .path = "conflict/src/lib.rs", .text = "extern crate util;\nmod util;\nuse util::Thing;\n" },
        .{ .path = "conflict/src/util.rs", .text = "" },
    } }).scan(a, .{});
    defer graph.deinit();
    try std.testing.expect((try reference(&graph, "src/lib.rs", "util::Thing")).resolved);
    try std.testing.expect((try reference(&graph, "src/lib.rs", "util::Body")).resolved);
    try std.testing.expect((try reference(&graph, "src/nested.rs", "deep::D")).resolved);
    try f.edge(&graph, "src/nested.rs", "src/nested/deep.rs", .import, 2);
    // An inline module is this file: no reference, as before.
    for (graph.references()) |ref| try std.testing.expect(!std.mem.eql(u8, ref.name, "inline::I"));
    try std.testing.expect(!(try reference(&graph, "src/lib.rs", "util::Other")).resolved);
    try std.testing.expect(!(try reference(&graph, "src/lib.rs", "util::Global")).resolved);
    try std.testing.expect(!(try reference(&graph, "conflict/src/lib.rs", "util::Thing")).resolved);
    // The declaration's own edge stays; the conflicting use adds none.
    try f.edge(&graph, "conflict/src/lib.rs", "conflict/src/util.rs", .import, 1);
}
test "Zig imports a .zon file beside the importer" {
    var graph = try (f.Fixture{ .items = &.{
        .{ .path = "src/a.zig", .text = "const d = @import(\"data.zon\"); const m = @import(\"data\");" },
        .{ .path = "src/data.zon", .text = ".{}" },
    } }).scan(a, .{});
    defer graph.deinit();
    try std.testing.expectEqual(1, graph.edges().len);
    try f.edge(&graph, "src/a.zig", "src/data.zon", .import, 1);
}
