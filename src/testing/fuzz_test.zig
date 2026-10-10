//! Properties that hold for any bytes, checked by shakedown's `check` for every
//! lexer and every manifest and config reader. `zig build test` runs each over
//! its examples and then seeded cases; `zig build test --fuzz` searches. Dependency rules
//! run over every manifest graph, and import spellings give package names.
//!
//! For each input: nothing panics or leaks, a scan fails only with an error a
//! reader documents, output is bounded by the input, and the same bytes give
//! the same result twice.
const dependency_check_module = @import("../rules/dependency_check.zig");
const std = @import("std");
const testing = std.testing;
const g = @import("../gantry.zig");
const f = @import("support.zig");
const lexer = @import("../lexer.zig");
const tokens = @import("../tokens.zig");
const manifests = @import("../manifests.zig");

/// The longest input a property reads.
const most = 4096;

const shakedown = @import("shakedown");

/// Bytes of any kind, up to `most`.
fn bytesOf(c: *shakedown.Case) error{OutOfMemory}![]u8 {
    return shakedown.gen.string(c.source, c.gpa, .{ .kind = .bytes, .max_len = most, .average = 256 });
}

/// `run` over each example, which is an input worth keeping as one, and then
/// over any bytes.
fn property(comptime run: fn ([]const u8) anyerror!void, examples: []const []const u8) !void {
    const Any = struct {
        fn body(_: void, c: *shakedown.Case) anyerror!void {
            try run(try bytesOf(c));
        }
    };
    for (examples) |text| try run(text);
    try shakedown.check(testing.allocator, {}, Any.body, .{});
}

/// One file read from memory.
const One = struct {
    path: []const u8,
    text: []const u8,
    fn read(one: One, a: std.mem.Allocator, _: std.Io, path: []const u8) !?[]const u8 {
        if (std.mem.eql(u8, path, one.path)) {
            const value = try a.dupe(u8, one.text);
            return value;
        }
        return "";
    }
};

/// Errors a single-file reader returns for bytes it cannot read: a
/// `FileError`, which a scan records instead.
fn documented(err: anyerror) bool {
    inline for (@typeInfo(g.FileError).error_set.error_names.?) |name| {
        if (err == @field(anyerror, name)) return true;
    }
    return false;
}

const everything: []const g.rules.TokenRule = &.{
    .{ .name = "names", .tokens = &.{"*"} },
    .{ .name = "values", .kind = .string, .tokens = &.{"*"} },
};

/// A scan fails only for its reader; bytes it cannot read are records.
fn scanOnce(paths: []const []const u8, one: One, options: g.Options) !g.Graph {
    return f.scan(testing.allocator, std.testing.io, paths, one, One.read, options) catch |err| {
        std.debug.print("scan of {s} failed: {s}\n", .{ one.path, @errorName(err) });
        return err;
    };
}

/// Scan `paths`, the first holding `text`, twice, and compare what came out.
fn scanTwice(paths: []const []const u8, text: []const u8, options: g.Options) !void {
    const one: One = .{ .path = paths[0], .text = text };
    var first = try scanOnce(paths, one, options);
    defer first.deinit();
    var second = try scanOnce(paths, one, options);
    defer second.deinit();
    // Only the file holding the bytes can be invalid, the same way twice.
    try testing.expectEqual(first.invalid().len, second.invalid().len);
    for (first.invalid(), second.invalid()) |x, y| {
        try testing.expectEqualStrings(paths[0], x.path);
        try testing.expectEqualStrings(x.path, y.path);
        try testing.expectEqual(x.cause, y.cause);
        try testing.expectEqual(x.offset, y.offset);
    }
    try sameGraph(&first, &second);
    try testing.expect(first.references().len <= text.len);
    try testing.expect(first.dependencies().len <= text.len);
    try testing.expect(first.tokens().len <= text.len);
    try checkTokens(&first, text);
    if (options.manifests) try checkDependencies(&first);
}

/// A dependency rule over any graph reports at most once per reference and
/// declaration, each finding with its evidence.
fn checkDependencies(graph: *const g.Graph) !void {
    var findings_owned = try graph.check(testing.allocator, .{ .dependencies = &.{.{ .name = "deps", .unused = &.{ .runtime, .development, .optional, .build } }} });
    defer findings_owned.deinit();
    const findings = findings_owned.items();
    try testing.expect(findings.len <= graph.references().len + graph.dependencies().len);
    for (findings) |finding| switch (finding.reason) {
        .undeclared => try testing.expect(finding.reference != null and finding.package != null and finding.path != null),
        .unused => try testing.expect(finding.dependency != null),
        else => return error.TestUnexpectedResult,
    };
}

fn sameGraph(x: *const g.Graph, y: *const g.Graph) !void {
    try testing.expectEqual(x.edges().len, y.edges().len);
    for (x.edges(), y.edges()) |a, b| {
        try testing.expectEqualStrings(a.from, b.from);
        try testing.expectEqualStrings(a.to, b.to);
        try testing.expectEqual(a.count, b.count);
    }
    try testing.expectEqual(x.references().len, y.references().len);
    for (x.references(), y.references()) |a, b| {
        try testing.expectEqualStrings(a.name, b.name);
        try testing.expectEqual(a.offset, b.offset);
    }
    try testing.expectEqual(x.dependencies().len, y.dependencies().len);
    for (x.dependencies(), y.dependencies()) |a, b| {
        try testing.expectEqualStrings(a.name, b.name);
        try testing.expectEqualStrings(a.requirement, b.requirement);
        try testing.expectEqualStrings(a.source, b.source);
    }
    try testing.expectEqual(x.unsupported().len, y.unsupported().len);
    try testing.expectEqual(x.tokens().len, y.tokens().len);
    for (x.tokens(), y.tokens()) |a, b| {
        try testing.expectEqualStrings(a.text, b.text);
        try testing.expectEqual(a.offset, b.offset);
    }
}

/// Recorded tokens are in order, lie inside the file, say where they are,
/// and a name is the bytes at its offset.
fn checkTokens(graph: *const g.Graph, text: []const u8) !void {
    var last: usize = 0;
    for (graph.tokens()) |token| {
        try testing.expect(token.offset >= last and token.offset < text.len);
        last = token.offset;
        var line: usize = 1;
        var start: usize = 0;
        for (text[0..token.offset], 0..) |c, i| if (c == '\n') {
            line += 1;
            start = i + 1;
        };
        try testing.expectEqual(line, token.line);
        try testing.expectEqual(token.offset - start + 1, token.column);
        try testing.expect(token.text.len <= text.len - token.offset);
        // A Zig `@"name"` starts at its `@` and is spelled otherwise than it reads.
        if (token.kind == .identifier and text[token.offset] != '@') try testing.expectEqualStrings(token.text, text[token.offset..][0..token.text.len]);
    }
}

/// The lexer emits ordered tokens inside the text, no more than one per
/// byte, the same way twice, and fails only for memory. A string's value is
/// never longer than its spelling. Without newlines it emits the rest alike.
fn checkLexer(comptime syntax: lexer.Syntax, language: ?g.Language, text: []const u8) !void {
    const a = testing.allocator;
    const first = lexer.lex(syntax, a, text) catch |err| switch (err) {
        error.OutOfMemory => return err,
    };
    defer a.free(first);
    const second = try lexer.lex(syntax, a, text);
    defer a.free(second);
    try testing.expect(first.len <= text.len);
    try testing.expectEqual(first.len, second.len);
    var last: usize = 0;
    for (first, second) |x, y| {
        try testing.expectEqual(x.kind, y.kind);
        try testing.expectEqual(x.offset, y.offset);
        try testing.expectEqual(x.end, y.end);
        try testing.expect(x.offset >= last and x.offset <= x.end and x.end <= text.len);
        last = x.offset;
        const at = @intFromPtr(x.text.ptr) -% @intFromPtr(text.ptr);
        try testing.expect(x.text.len == 0 or (at >= x.offset and at + x.text.len <= x.end));
        if (language) |lang| if (x.kind == .string) {
            var arena: std.heap.ArenaAllocator = .init(a);
            defer arena.deinit();
            for ([_]bool{ false, true }) |keep| {
                const value = try tokens.value(arena.allocator(), lang, x.text, keep);
                try testing.expect(value.len <= x.text.len);
                try testing.expectEqualStrings(value, try tokens.value(arena.allocator(), lang, x.text, keep));
            }
        };
    }
    // The compact lexer emits the same stream without its newlines.
    const compacted = try lexer.lexCompact(syntax, a, text, null);
    defer a.free(compacted);
    const kept = lexer.compact(second);
    try testing.expectEqual(kept.len, compacted.len);
    for (kept, compacted) |x, y| {
        try testing.expectEqual(x.kind, y.kind);
        try testing.expectEqual(x.offset, y.offset);
        try testing.expectEqual(x.end, y.end);
        try testing.expectEqualStrings(x.text, y.text);
    }
}

/// Lexing, import recovery and a scan recording every name and string.
fn source(comptime language: g.Language, comptime path: []const u8, comptime corpus: []const []const u8) !void {
    const Property = struct {
        fn one(text: []const u8) anyerror!void {
            // Zig is read by glint, whose tokenizer is not this package's to fuzz.
            if (comptime language != .zig) try checkLexer(@field(lexer.Syntax, @tagName(language)), language, text);
            if (f.imports(testing.allocator, language, text)) |recovered| {
                var imports = recovered;
                defer imports.deinit();
                try testing.expect(imports.items().len <= text.len);
                try testing.expect(imports.unsupported().len <= text.len);
            } else |err| if (!documented(err)) return err;
            try scanTwice(&.{path}, text, .{ .manifests = false, .tokens = everything });
        }
    };
    try property(Property.one, corpus);
}

/// A manifest or config read through a scan, beside a source that can use it.
fn manifest(comptime paths: []const []const u8, comptime syntax: ?lexer.Syntax, comptime corpus: []const []const u8) !void {
    const Property = struct {
        fn one(text: []const u8) anyerror!void {
            if (syntax) |s| try checkLexer(s, null, text);
            if (manifests.supported(paths[0])) {
                var arena: std.heap.ArenaAllocator = .init(testing.allocator);
                defer arena.deinit();
                if (manifests.read(arena.allocator(), paths[0], text)) |declared| {
                    try testing.expect(declared.dependencies.len <= text.len);
                    try testing.expect(declared.unsupported.len <= text.len);
                } else |err| if (err != error.UnsupportedManifest and !documented(err)) return err;
            }
            try scanTwice(paths, text, .{});
        }
    };
    try property(Property.one, corpus);
}

// Seeds follow the bench corpus: an import, a long comment and a string
// that only looks like an import, plus each language's awkward literals.

test "fuzz: Zig source" {
    try source(.zig, "src/a.zig", &.{
        "const dep = @import(\"f0.zig\");\n// comment comment\nconst text = \"@import(\\\"fake.zig\\\")\";\n",
        "const s = \\\\multi \"line\"\n;\nconst c = '\\x1b'; const q = @\"name\"; const e = \"\\u{1b}[0m\";",
        "const std = @import(\"std\"); const x = std.mem.eql; test { _ = @import(\"t.zig\").T; }",
    });
}
test "fuzz: C source" {
    try source(.c, "src/a.h", &.{
        "#include \"f0.h\"\n/* comment */\nconst char *s = \"#include fake\";\n",
        "#include <sys/types.h>\n#define X \\\n  1\nconst char *r = R\"x(a\"b)x\"; char c = '\\033'; const char *e = \"\\e[\\x1b]\";",
        "#if 0\n#include \"g.h\"\n#endif\n// line\n#include",
        "#if 0\nthis won't build\n#endif\n#include \"c.h\"\n",
    });
}
test "fuzz: JavaScript and TypeScript source" {
    try source(.javascript, "src/a.ts", &.{
        "import './f0';\nconst dep = import('./f0');\n// comment\nconst text = `import './fake'`;\n",
        "const r = /a\\/b[/]/g; const t = `x ${ `y ${\"z\"}` } w`; require('./x'); export * from \"./y\";",
        "import type { A } from './a'; const s = '\\u{1b}[' + \"\\x1b]\"; label: { break label; }",
        "const A = () => <p>Don't</p>;\nconst B = lazy(() => import('./B.jsx'));\n",
    });
}
test "fuzz: Python source" {
    try source(.python, "py/a.py", &.{
        "import g0.f0\n# comment\ntext = \"import fake\"\n",
        "from . import x, y\nfrom ..a.b import (c,\n d)\n__all__ = ['x', \"y\"]\ns = r'\\x1b[' + b'\\033[' + '''triple'''\n",
        "import importlib\nm = importlib.import_module('x')\n__import__('y')\nif a: \\\n  import z\n",
    });
}
test "fuzz: Go source" {
    try source(.go, "go/a.go", &.{
        "package g0\nimport \"example.com/bench/g0\"\n// comment\nvar text = `import \"fake\"`\n",
        "//go:build linux && !cgo\n\npackage a\n\nimport (\n\tf \"fmt\"\n\t_ \"embed\"\n)\nvar r = '\\x1b'\nvar s = \"\\033[\\u001b]\"\n",
        "// +build ignore\npackage a_test\nimport . \"example.com/x\"\n",
    });
}
test "fuzz: Rust source" {
    try source(.rust, "rust/src/a.rs", &.{
        "use super::f0::Thing;\n// comment\nlet text = r#\"use crate::fake;\"#;\n",
        "#[cfg(test)] mod tests { use super::*; }\nmod a; pub mod b;\nfn f<'a>(x: &'a str) -> char { 'x' }\n/* a /* nested */ b */ include!(\"x.rs\");",
        "use crate::{a::{b, c}, d as e}; let s = \"\\x1b[\\u{1b}]\"; let b = b'\\n';",
        "use ::serde::de; extern crate libc as c; #[tokio::main] fn f() { serde_json::to_string(&1); Vec::<u8>::new(); x.y::<T>(); $crate::z; }",
    });
}
test "fuzz: Nim source" {
    try source(.nim, "src/a.nim", &.{
        "import std/os, ./b, ../c/d\ninclude e\nfrom f import g\n# comment\n",
        "#[ block #[ nested ]# ]#\nlet s = \"\\e[\\27]\"\nlet r = r\"raw\\\" & fmt\"{x}\" & \"\"\"triple\"\"\"\nlet c = '\\n'\nlet n = 1'i8\n",
        "when defined(windows):\n  import winlean\nelse:\n  import posix\nimport a/[b, c] except d\n",
    });
}
test "fuzz: Java source" {
    try source(.java, "src/main/java/a/B.java", &.{
        "package a;\nimport java.util.List;\nimport static a.C.d;\nimport a.b.*;\n// comment\nclass B { String s = \"import fake\"; }\n",
        "package a; class B { String t = \"\"\"\n  text block \\\"\"\" \n  \"\"\"; char c = '\\''; Object o = Class.forName(\"x\"); }",
        "/** doc */ module m { requires java.base; }",
    });
}

test "fuzz: build.zig.zon" {
    try manifest(&.{"build.zig.zon"}, null, &.{
        ".{ .name = .x, .version = \"0.1.0\", .dependencies = .{ .a = .{ .url = \"git+https://h/a#v1\", .hash = \"a-1\" }, .@\"b-c\" = .{ .path = \"../b\", .lazy = true } }, .paths = .{\"\"} }",
        ".{ .dependencies = .{} }",
    });
}
test "fuzz: package.json" {
    try manifest(&.{ "package.json", "a.ts" }, null, &.{
        "{\"dependencies\":{\"external\":\"1\"}}\n",
        "{\"name\":\"x\",\"dependencies\":{\"k\":\"github:me/k#main\",\"l\":\"file:../l\",\"w\":\"workspace:*\"},\"devDependencies\":{\"t\":\"^1\"},\"optionalDependencies\":{}}",
    });
}
test "fuzz: Cargo.toml" {
    try manifest(&.{"Cargo.toml"}, .python, &.{
        "[package]\nname = 'x'\n[dependencies]\nserde = \"1\"\nengine = { git = \"https://h/e\", branch = \"main\" }\n[dev-dependencies]\nlocal = { path = \"../l\" }\n[target.'cfg(unix)'.build-dependencies]\ncc = '1'\n",
        "[workspace.dependencies]\na = { workspace = true }\n[dependencies.b]\nversion = \"2\"\n",
        "[[bin]]\nname = 'tool'\n[dependencies]\nserde.version = \"1\"\nserde.features = [\"derive\"]\n\"q.x\".path = '../q'\n[[bench]]\nharness = false\n",
    });
}
test "fuzz: pyproject.toml" {
    try manifest(&.{"pyproject.toml"}, .python, &.{
        "[project]\nname = 'tool'\ndependencies = [\n 'requests>=2',\n 'mylib @ git+https://h/m.git@v1',\n]\n[project.optional-dependencies]\nx = ['y']\n",
        "[tool.poetry.dependencies]\npython = \"^3.11\"\nz = { path = \"../z\" }\n[dependency-groups]\ndev = ['pytest']\n",
        "[project]\ndependencies = ['a']\n[[tool.mypy.overrides]]\nmodule = 'x.*'\n[[tool.poetry.source]]\nname = 'm'\n",
    });
}
test "fuzz: go.mod" {
    try manifest(&.{ "go.mod", "a.go" }, .go, &.{
        "module example.com/bench\nrequire example.com/external v1.0.0\n",
        "module example.com/me/cli\n\ngo 1.22\n\nrequire (\n\tgithub.com/me/core v1.2.0 // indirect\n)\nreplace github.com/me/core => ../core\n",
    });
}
test "fuzz: go.work" {
    try manifest(&.{ "go.work", "a/go.mod" }, .go, &.{
        "go 1.22\n\nuse (\n\t./a\n\t../b\n)\nreplace example.com/x v1.0.0 => ./x\n",
    });
}
test "fuzz: .nimble" {
    try manifest(&.{"pkg.nimble"}, .nim, &.{
        "version = \"0.1.0\"\nrequires \"nim >= 2.0\", \"https://h/x#head\"\ntaskRequires \"test\", \"unittest2\"\nfeature \"x\":\n  requires \"y\"\n",
        "requires(\"a\")\nrequires someVar\n",
    });
}
test "fuzz: pom.xml" {
    try manifest(&.{"pom.xml"}, null, &.{
        "<project><groupId>g</groupId><artifactId>a</artifactId><version>1</version><properties><v>2</v></properties><dependencies><dependency><groupId>x</groupId><artifactId>y</artifactId><version>${v}</version><scope>test</scope><optional>true</optional></dependency></dependencies></project>",
        "<?xml version=\"1.0\"?><!-- c --><project><dependencies><dependency><groupId>${missing}</groupId></dependency></dependencies></project>",
    });
}
test "fuzz: build.gradle" {
    try manifest(&.{"build.gradle"}, .groovy, &.{
        "dependencies {\n  implementation 'g:a:1'\n  testImplementation group: 'g', name: 'b', version: '2'\n  api project(':libs:x')\n  implementation \"g:c:$v\"\n}\n",
        "buildscript { dependencies { classpath 'g:p:1' } }\ndependencies { implementation libs.foo }\n",
    });
}
test "fuzz: build.gradle.kts" {
    try manifest(&.{"build.gradle.kts"}, .kotlin, &.{
        "dependencies {\n    implementation(\"g:a:1\")\n    testImplementation(platform(\"g:bom:2\"))\n    `api`(project(\":x\"))\n}\n",
    });
}
test "fuzz: tsconfig.json" {
    try manifest(&.{ "tsconfig.json", "src/a.ts" }, null, &.{
        "{\n  // comment\n  \"compilerOptions\": { \"baseUrl\": \".\", \"paths\": { \"@/*\": [\"src/*\"], }, },\n  /* block */ \"extends\": \"./base.json\",\n}\n",
        "{\"extends\": [\"./a.json\", \"./b.json\"], \"compilerOptions\": {\"paths\": {\"x\": [\"y\"]}}}",
    });
}
test "fuzz: jsconfig.json" {
    try manifest(&.{ "jsconfig.json", "src/a.js" }, null, &.{
        "{\"compilerOptions\":{\"baseUrl\":\"src\"}}",
    });
}

test "fuzz: package names in import spellings" {
    const dependencies = dependency_check_module;
    const Property = struct {
        fn one(text: []const u8) anyerror!void {
            for (std.enums.values(dependencies.Ecosystem)) |e| {
                // A package is a slice of the spelling, never more.
                const package = dependencies.packageOf(e, text) orelse continue;
                try testing.expect(package.len > 0 and @intFromPtr(package.ptr) >= @intFromPtr(text.ptr) and @intFromPtr(package.ptr) + package.len <= @intFromPtr(text.ptr) + text.len);
                try testing.expect(dependencies.declares(e, .{ .manifest = "m", .name = package }, package) or e == .java);
            }
        }
    };
    try property(Property.one, &.{ "@scope/pkg/sub", "node:fs", "requests.adapters.X", "::serde::de", "github.com/x/y/v2/pkg", "pkg/foo/bar", "com.google.common.collect.List", "" });
}

test "fuzz: Zig test context changes kinds only" {
    const Property = struct {
        fn one(text: []const u8) anyerror!void {
            const one_file: One = .{ .path = "src/a.zig", .text = text };
            const paths: []const []const u8 = &.{ "src/a.zig", "src/b.zig", "src/c.zig" };
            var classified = try scanOnce(paths, one_file, .{ .manifests = false });
            defer classified.deinit();
            // Every import a test import: the pairs recovery gives unclassified.
            var plain = try scanOnce(paths, one_file, .{ .manifests = false, .test_paths = &.{"**"} });
            defer plain.deinit();
            try testing.expectEqual(plain.references().len, classified.references().len);
            for (plain.references(), classified.references()) |x, y| {
                try testing.expectEqualStrings(x.name, y.name);
                try testing.expectEqual(x.offset, y.offset);
                try testing.expectEqualStrings(x.member orelse "", y.member orelse "");
                try testing.expectEqual(x.resolved, y.resolved);
                try testing.expect(x.kind == .@"test" and (y.kind == .import or y.kind == .@"test"));
            }
            // Coalesced by kind, so one plain edge is up to two classified ones.
            var total: usize = 0;
            for (classified.edges()) |e| {
                total += e.count.raw();
                var found = false;
                for (plain.edges()) |p| found = found or (std.mem.eql(u8, p.from, e.from) and std.mem.eql(u8, p.to, e.to));
                try testing.expect(found);
            }
            for (plain.edges()) |p| {
                try testing.expectEqual(g.Kind.@"test", p.kind);
                total -= p.count.raw();
            }
            try testing.expectEqual(0, total);
        }
    };
    try property(Property.one, &.{
        "const b = @import(\"b.zig\");\npub fn run() void { b.go(); }\ntest { _ = @import(\"c.zig\"); }\n",
        "const builtin = @import(\"builtin\");\nconst c = @import(\"c.zig\");\nfn helper() void { _ = c; }\npub const T = if (builtin.is_test) @import(\"b.zig\") else struct {};\ntest { helper(); }\n",
        "const Self = @This();\nconst b = @import(\"b.zig\");\nx: u8,\npub fn f(s: Self) void { s.g(); }\nfn g(_: Self) void { _ = b; }\ntest \"g\" { _ = @import(\"b.zig\").T; }\n",
    });
}
