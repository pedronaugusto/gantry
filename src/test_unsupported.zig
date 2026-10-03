const std = @import("std");
const g = @import("gantry.zig");
const f = @import("test_support.zig");
const a = std.testing.allocator;

fn unsupportedCount(result: anytype) usize {
    return result.unsupported().len;
}

fn lexical(language: g.Language, source: []const u8, count: usize) !void {
    var result = try g.imports(a, language, source);
    defer result.deinit();
    try std.testing.expectEqual(count, unsupportedCount(&result));
    for (result.unsupported(), 0..) |record, i| {
        try std.testing.expectEqual(null, record.from);
        if (i > 0) try std.testing.expect(result.unsupported()[i - 1].offset < record.offset);
        const rest = source[record.offset..];
        const spelling: []const u8 = switch (record.expression) {
            .zig_import => "@import",
            .c_include => "#include",
            .javascript_import => "import",
            .javascript_require => "require",
            .python_importlib => "importlib.import_module",
            .python_import => "__import__",
            .rust_include => "include!",
            .rust_path => "#[path",
            .nim_import => if (std.mem.startsWith(u8, rest, "from")) "from" else "import",
            .nim_include => "include",
        };
        try std.testing.expect(std.mem.startsWith(u8, rest, spelling));
    }
}

test "unsupported Zig imports retain every computed and malformed expression" {
    try lexical(.zig,
        \\const name = "a.zig";
        \\const a = @import(name);
        \\const b = @import("a" ++ ".zig");
        \\const c = @import(("a.zig"));
        \\const d = @import(if (true) "a.zig" else "b.zig");
        \\const e = @import(makeName());
        \\const f = @import();
        \\const g = @import("a.zig",);
        \\const h = @import
    , 8);
    try lexical(.zig,
        \\// @import(name)
        \\const text = "@import(name)";
        \\const a = @import( // comment
        \\    "a.zig"
        \\);
    , 0);
}

test "unsupported JavaScript imports distinguish calls from member access and template text" {
    try lexical(.javascript,
        \\import(name); require(name); import('./' + name); require('a' + suffix);
        \\import(`./${name}.js`); import(`./a.js`);
        \\const nested = `text ${import(other)} and ${require(last)}`;
        \\import('./a.js', {with: {type: 'json'}});
        \\obj.import(name); obj.require(name); import.meta;
        \\// import(name)
        \\const text = "require(name)"; const template = `import(name)`;
        \\const regex = /import(name)/;
    , 8);
}

test "unsupported Python imports expose direct runtime loaders without guessing aliases" {
    try lexical(.python,
        \\import importlib
        \\importlib.import_module(name)
        \\importlib.import_module('pkg' + suffix)
        \\importlib.import_module('pkg')
        \\__import__(name)
        \\__import__('pkg')
        \\other.import_module(name)
        \\other.__import__(name)
        \\# importlib.import_module(name)
        \\text = "__import__(name)"
        \\from pkg import child
    , 5);
}

test "unsupported C includes expose macro operands and ignore directive text" {
    try lexical(.c,
        \\#include HEADER
        \\#include MAKE_HEADER(name)
        \\#include
        \\#include "literal.h"
        \\#include <system.h>
        \\// #include HEADER
        \\const char *text = "#include HEADER";
    , 3);
}

test "unsupported Rust imports expose include macros and path attributes" {
    try lexical(.rust,
        \\include!(concat!(env!("OUT_DIR"), "/generated.rs"));
        \\include!("generated.rs");
        \\#[path = "other.rs"] mod renamed;
        \\#[path = concat!("a", ".rs")] mod computed;
        \\mod child; use crate::child;
        \\// include!(name)
        \\const TEXT: &str = "include!(name)";
    , 4);
}

test "unsupported Nim imports keep no module from a statement they cannot read" {
    try lexical(.nim,
        \\import $name
        \\import a, b & "c"
        \\include (name)
        \\from strutils & x import y
        \\import a/[b, $c]
        \\import a/
        \\import std/[os, strutils], ../lib/x as y, "z/w"
        \\from a/b import c, d
        \\when defined(x): import e except f
        \\# import $bad
        \\let text = "import $bad"
        \\proc p() {.importc.}
    , 6);
    var result = try g.imports(a, .nim, "import a, b & \"c\"\nimport d");
    defer result.deinit();
    try std.testing.expectEqual(1, result.items().len);
    try std.testing.expectEqualStrings("d", result.items()[0].name);
}

test "unsupported Go imports do not invent computed syntax for valid declarations" {
    var result = try g.imports(a, .go,
        \\package p
        \\import "one"
        \\import ( alias "two"; _ `three`; . "four" )
        \\// import computed
        \\var text = "import computed"
    );
    defer result.deinit();
    try std.testing.expectEqual(4, result.items().len);
    try std.testing.expectEqual(0, unsupportedCount(&result));
}

fn strictOptions() g.Options {
    var options: g.Options = .{ .manifests = false };
    options.strict_imports = true;
    return options;
}

fn refuse(fixture: f.Fixture, paths: []const []const u8, diagnostic: ?*g.ScanDiagnostic) !void {
    if (g.scanWithDiagnostic(a, paths, fixture, f.Fixture.read, strictOptions(), diagnostic)) |value| {
        var graph = value;
        defer graph.deinit();
        return error.TestExpectedUnsupportedImport;
    } else |cause| try std.testing.expectEqual(error.UnsupportedImport, cause);
}

test "unsupported strict scans refuse omitted imports before returning a graph" {
    const fixture: f.Fixture = .{ .items = &.{
        .{ .path = "a.zig", .text = "const b = @import(\"b.zig\"); const c = @import(name);" },
        .{ .path = "b.zig" },
    } };
    try refuse(fixture, &.{ "b.zig", "a.zig" }, null);
    var diagnostic = g.ScanDiagnostic.init(a);
    defer diagnostic.deinit();
    try refuse(fixture, &.{ "b.zig", "a.zig" }, &diagnostic);
    const failure = diagnostic.failure orelse return error.TestExpectedDiagnostic;
    try std.testing.expectEqualStrings("a.zig", failure.path.?);
    try std.testing.expectEqual(g.ScanDiagnostic.Phase.imports, failure.phase);
    try std.testing.expectEqual(error.UnsupportedImport, failure.cause);
    try std.testing.expectEqual(@as(?usize, 38), failure.offset);
}

test "unsupported tolerant scans own records in sorted source order" {
    const fixture: f.Fixture = .{ .items = &.{
        .{ .path = "b.js", .text = "import(name); require(other);" },
        .{ .path = "a.zig", .text = "@import(name); @import(\"literal.zig\"); @import(next);" },
        .{ .path = "literal.zig" },
    } };
    var graph = try fixture.scan(a, .{ .manifests = false });
    defer graph.deinit();
    try std.testing.expectEqual(4, unsupportedCount(&graph));
    try std.testing.expectEqual(1, graph.references().len);
    try f.edge(&graph, "a.zig", "literal.zig", .import, 1);
    {
        const records = graph.unsupported();
        try std.testing.expectEqualStrings("a.zig", records[0].from.?);
        try std.testing.expectEqual(@as(usize, 0), records[0].offset);
        try std.testing.expectEqualStrings("a.zig", records[1].from.?);
        try std.testing.expectEqualStrings("b.js", records[2].from.?);
        try std.testing.expectEqualStrings("b.js", records[3].from.?);
        try std.testing.expectEqual(g.ImportExpression.zig_import, records[0].expression);
        try std.testing.expectEqual(g.ImportExpression.javascript_import, records[2].expression);
        try std.testing.expectEqual(g.ImportExpression.javascript_require, records[3].expression);
    }
}

test "unsupported templates cannot promote interpolated strings into literal imports" {
    var result = try g.imports(a, .javascript,
        \\import(`prefix${'./wrong.js'}suffix`);
        \\require(`${"./wrong.js"}`);
        \\import(`prefix${import('./right.js')}suffix`);
    );
    defer result.deinit();
    try std.testing.expectEqual(1, result.items().len);
    try std.testing.expectEqualStrings("./right.js", result.items()[0].name);
    try std.testing.expectEqual(3, result.unsupported().len);
}

test "unsupported path attributes never invent default Rust module edges" {
    const fixture: f.Fixture = .{ .items = &.{
        .{ .path = "src/lib.rs", .text = "#[path = \"elsewhere.rs\"] mod renamed; mod child;" },
        .{ .path = "src/renamed.rs" },
        .{ .path = "src/child.rs" },
        .{ .path = "src/elsewhere.rs" },
    } };
    var graph = try fixture.scan(a, .{ .manifests = false });
    defer graph.deinit();
    try std.testing.expectEqual(1, graph.edges().len);
    try f.edge(&graph, "src/lib.rs", "src/child.rs", .import, 1);
    try std.testing.expectEqual(1, graph.unsupported().len);
}

test "unsupported strict diagnostics cover every detecting language and survive cleanup" {
    var diagnostic = g.ScanDiagnostic.init(a);
    defer diagnostic.deinit();
    for ([_]struct { path: []const u8, source: []const u8, offset: usize }{
        .{ .path = "src/a.zig", .source = "\n@import(name)", .offset = 1 },
        .{ .path = "src/a.js", .source = "\nimport(name)", .offset = 1 },
        .{ .path = "src/a.ts", .source = "\nrequire(name)", .offset = 1 },
        .{ .path = "pkg/a.py", .source = "\nimportlib.import_module(name)", .offset = 1 },
        .{ .path = "src/a.cpp", .source = "\n#include HEADER", .offset = 1 },
        .{ .path = "src/a.rs", .source = "\ninclude!(name);", .offset = 1 },
        .{ .path = "src/a.nim", .source = "\ninclude $name", .offset = 1 },
    }) |case| {
        var inputs: std.heap.ArenaAllocator = .init(a);
        const path = try inputs.allocator().dupe(u8, case.path);
        const source = try inputs.allocator().dupe(u8, case.source);
        const fixture: f.Fixture = .{ .items = &.{.{ .path = path, .text = source }} };
        refuse(fixture, &.{path}, &diagnostic) catch |cause| {
            inputs.deinit();
            return cause;
        };
        inputs.deinit();
        try std.testing.expectEqualStrings(case.path, diagnostic.failure.?.path.?);
        try std.testing.expectEqual(@as(?usize, case.offset), diagnostic.failure.?.offset);
        try std.testing.expectEqual(g.ScanDiagnostic.Phase.imports, diagnostic.failure.?.phase);
    }
    var empty = try g.scanWithDiagnostic(a, &.{}, f.Fixture{ .items = &.{} }, f.Fixture.read, strictOptions(), &diagnostic);
    defer empty.deinit();
    try std.testing.expectEqual(null, diagnostic.failure);
}

test "unsupported strict scans inspect code even when edge kinds are disabled" {
    const fixture: f.Fixture = .{ .items = &.{.{ .path = "a.zig", .text = "@import(name)" }} };
    var options = strictOptions();
    options.kinds = &.{};
    if (fixture.scan(a, options)) |value| {
        var graph = value;
        defer graph.deinit();
        return error.TestExpectedUnsupportedImport;
    } else |cause| try std.testing.expectEqual(error.UnsupportedImport, cause);
}

test "unsupported diagnostic offsets survive failure to allocate a path" {
    var storage: [0]u8 = .{};
    var fixed: std.heap.FixedBufferAllocator = .init(&storage);
    var diagnostic = g.ScanDiagnostic.init(fixed.allocator());
    defer diagnostic.deinit();
    const fixture: f.Fixture = .{ .items = &.{.{ .path = "a.zig", .text = " @import(name)" }} };
    try refuse(fixture, &.{"a.zig"}, &diagnostic);
    try std.testing.expectEqual(null, diagnostic.failure.?.path);
    try std.testing.expectEqual(@as(?usize, 1), diagnostic.failure.?.offset);
    try std.testing.expectEqual(error.UnsupportedImport, diagnostic.failure.?.cause);
}

test "unsupported lexical and graph owners retain records after their inputs are overwritten" {
    const source = try a.dupe(u8, "@import(name); @import(\"b.zig\");");
    defer a.free(source);
    const path = try a.dupe(u8, "src/a.zig");
    defer a.free(path);
    var result = try g.imports(a, .zig, source);
    defer result.deinit();
    const fixture: f.Fixture = .{ .items = &.{
        .{ .path = path, .text = source },
        .{ .path = "src/b.zig" },
    } };
    var graph = try fixture.scan(a, .{ .manifests = false });
    defer graph.deinit();
    @memset(source, 'x');
    @memset(path, 'x');
    try std.testing.expectEqualStrings("b.zig", result.items()[0].name);
    try std.testing.expectEqual(null, result.unsupported()[0].from);
    try std.testing.expectEqual(g.ImportExpression.zig_import, result.unsupported()[0].expression);
    try std.testing.expectEqualStrings("src/a.zig", graph.unsupported()[0].from.?);
    try std.testing.expectEqual(@as(usize, 0), graph.unsupported()[0].offset);
}

fn lexicalAllocations(alloc: std.mem.Allocator) !void {
    inline for (comptime std.meta.tags(g.Language)) |language| {
        const source = switch (language) {
            .zig => "@import(name); @import(\"literal.zig\");",
            .c => "#include MACRO\n#include \"literal.h\"",
            .javascript => "import(name); import('./literal.js');",
            .python => "importlib.import_module(name)\nimport literal",
            .go => "package a\nimport \"literal\"",
            .rust => "include!(name); mod literal;",
            .nim => "import $name\nimport literal",
        };
        var result = try g.imports(alloc, language, source);
        defer result.deinit();
        try std.testing.expectEqual(if (language == .go) @as(usize, 0) else 1, result.unsupported().len);
        try std.testing.expectEqual(1, result.items().len);
    }
}

fn graphAllocations(alloc: std.mem.Allocator) !void {
    const fixture: f.Fixture = .{ .items = &.{
        .{ .path = "a.zig", .text = "@import(name); @import(\"b.zig\");" },
        .{ .path = "b.zig", .text = "@import(other);" },
    } };
    var graph = try fixture.scan(alloc, .{ .manifests = false });
    defer graph.deinit();
    try std.testing.expectEqual(2, graph.unsupported().len);
    try std.testing.expectEqual(1, graph.edges().len);
    var aggregate = try graph.aggregate(alloc, 1);
    defer aggregate.deinit();
    try std.testing.expectEqualDeep(graph.unsupported(), aggregate.unsupported());
}

test "unsupported recovery releases every lexical and graph allocation failure" {
    try std.testing.checkAllAllocationFailures(a, lexicalAllocations, .{});
    try std.testing.checkAllAllocationFailures(a, graphAllocations, .{});
}

test "unsupported directory graphs retain independent source evidence" {
    const fixture: f.Fixture = .{ .items = &.{.{ .path = "src/a.zig", .text = " @import(name)" }} };
    var graph = try fixture.scan(a, .{});
    var aggregate = graph.aggregate(a, 1) catch |cause| {
        graph.deinit();
        return cause;
    };
    defer aggregate.deinit();
    graph.deinit();
    try std.testing.expectEqualStrings("src/a.zig", aggregate.unsupported()[0].from.?);
    try std.testing.expectEqual(@as(usize, 1), aggregate.unsupported()[0].offset);
    try std.testing.expectEqual(g.ImportExpression.zig_import, aggregate.unsupported()[0].expression);
}

test "unsupported Python loader detection follows implicit line continuation" {
    const source =
        \\(importlib
        \\    .import_module
        \\    (name))
        \\(__import__
        \\    (other))
    ;
    var result = try g.imports(a, .python, source);
    defer result.deinit();
    try std.testing.expectEqual(2, result.unsupported().len);
    try std.testing.expectEqual(g.ImportExpression.python_importlib, result.unsupported()[0].expression);
    try std.testing.expectEqual(@as(usize, 1), result.unsupported()[0].offset);
    try std.testing.expectEqual(g.ImportExpression.python_import, result.unsupported()[1].expression);
    try std.testing.expectEqual(std.mem.indexOf(u8, source, "__import__").?, result.unsupported()[1].offset);
}

fn strictAllocations(alloc: std.mem.Allocator) !void {
    var diagnostic = g.ScanDiagnostic.init(a);
    defer diagnostic.deinit();
    const fixture: f.Fixture = .{ .items = &.{.{ .path = "a.zig", .text = "@import(name);" }} };
    if (g.scanWithDiagnostic(alloc, &.{"a.zig"}, fixture, f.Fixture.read, strictOptions(), &diagnostic)) |value| {
        var graph = value;
        defer graph.deinit();
        return error.TestExpectedUnsupportedImport;
    } else |cause| {
        if (cause == error.OutOfMemory) return cause;
        try std.testing.expectEqual(error.UnsupportedImport, cause);
        try std.testing.expectEqualStrings("a.zig", diagnostic.failure.?.path.?);
        try std.testing.expectEqual(@as(?usize, 0), diagnostic.failure.?.offset);
    }
}

test "unsupported strict failures release every scan allocation" {
    try std.testing.checkAllAllocationFailures(a, strictAllocations, .{});
}
