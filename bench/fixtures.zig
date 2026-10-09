//! Deterministic inputs for the benchmarks, written before and never inside
//! a measurement: the six-language synthetic corpus `scan` reads, and the
//! per-operation fixtures `ops` reads. Every source fixture is valid for the
//! language's own parser, and every comment or string spells an import that
//! must not count.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const repeat = @import("shakedown").corpus.repeat;
const comment120 = repeat("comment ", 120);
const comment16 = repeat("comment ", 16);

/// Writes `text` at `root/sub`, creating folders. With `only_if_changed`,
/// an identical file is left alone, so its timestamps stay.
pub const Writer = struct {
    io: Io,
    a: Allocator,
    root: []const u8,
    /// Off: compute paths only, as a pass that reads what preparation wrote.
    enabled: bool = true,
    only_if_changed: bool = true,

    pub fn write(w: Writer, sub: []const u8, text: []const u8) !void {
        if (!w.enabled) return;
        const full = try std.Io.Dir.path.join(w.a, &.{ w.root, sub });
        if (std.Io.Dir.path.dirname(full)) |parent| try Io.Dir.cwd().createDirPath(w.io, parent);
        if (w.only_if_changed) {
            if (Io.Dir.cwd().readFileAlloc(w.io, full, w.a, .unlimited)) |old| {
                if (std.mem.eql(u8, old, text)) return;
            } else |_| {}
        }
        try Io.Dir.cwd().writeFile(w.io, .{ .sub_path = full, .data = text });
    }
};

/// The synthetic corpus: `count` files in each of six languages, groups of
/// ten each importing the one before. Returns the code files' total bytes.
pub fn synthetic(w: Writer, count: usize) !usize {
    const a = w.a;
    var total: usize = 0;
    for ([_][]const u8{ "zig", "c", "js", "py", "go", "rust" }) |lang| {
        for (0..count) |i| {
            const group = i / 10;
            const member = i % 10;
            const prev = if (member == 0) 0 else member - 1;
            var path: []const u8 = undefined;
            var text: []const u8 = undefined;
            var filler: []const u8 = undefined;
            if (std.mem.eql(u8, lang, "zig")) {
                path = try a.print("zig/g{d}/f{d}.zig", .{ group, member });
                text = try a.print("const dep = @import(\"f{d}.zig\");\n", .{prev});
                filler = "// " ++ comment120 ++ "\nconst text = \"@import(\\\"fake.zig\\\")\";\n";
            } else if (std.mem.eql(u8, lang, "c")) {
                path = try a.print("c/g{d}/f{d}.h", .{ group, member });
                text = try a.print("#include \"f{d}.h\"\n", .{prev});
                filler = "/* " ++ comment120 ++ " */\nconst char *s = \"#include fake\";\n";
            } else if (std.mem.eql(u8, lang, "js")) {
                path = try a.print("js/g{d}/f{d}.ts", .{ group, member });
                text = try a.print("import './f{d}';\nconst dep = import('./f{d}');\n", .{ prev, prev });
                filler = "// " ++ comment120 ++ "\nconst text = `import './fake'`;\n";
            } else if (std.mem.eql(u8, lang, "py")) {
                path = try a.print("py/g{d}/f{d}.py", .{ group, member });
                text = try a.print("import g{d}.f{d}\n", .{ group, prev });
                filler = "# " ++ comment120 ++ "\ntext = \"import fake\"\n";
            } else if (std.mem.eql(u8, lang, "go")) {
                path = try a.print("go/g{d}/f{d}.go", .{ group, member });
                text = try a.print("package g{d}\nimport \"example.com/bench/g{d}\"\n", .{ group, if (group == 0) 0 else group - 1 });
                filler = "// " ++ comment120 ++ "\nvar text = `import \"fake\"`\n";
            } else {
                path = try a.print("rust/src/g{d}/f{d}.rs", .{ group, member });
                text = try a.print("use super::f{d}::Thing;\n", .{prev});
                filler = "// " ++ comment120 ++ "\nlet text = r#\"use crate::fake;\"#;\n";
            }
            const data = try std.mem.concat(a, u8, &.{ text, filler });
            try w.write(path, data);
            total += data.len;
        }
    }
    try w.write("go/go.mod", "module example.com/bench\nrequire example.com/external v1.0.0\n");
    try w.write("package.json", "{\"dependencies\":{\"external\":\"1\"}}\n");
    return total;
}

pub const Size = enum { small, medium, large };
pub const sizes = [_]Size{ .small, .medium, .large };

/// Imports per file: a small module, a large module, a generated file.
pub fn importCount(size: Size) usize {
    return switch (size) {
        .small => 20,
        .medium => 200,
        .large => 5000,
    };
}
/// Declared dependencies per manifest.
pub fn manifestCount(size: Size) usize {
    return switch (size) {
        .small => 10,
        .medium => 100,
        .large => 1000,
    };
}

pub const languages = [_][2][]const u8{
    .{ "zig", ".zig" }, .{ "c", ".h" },     .{ "javascript", ".ts" }, .{ "python", ".py" },
    .{ "go", ".go" },   .{ "rust", ".rs" }, .{ "nim", ".nim" },       .{ "java", ".java" },
};
pub const manifests = [_][]const u8{ "package.json", "Cargo.toml", "pyproject.toml", "go.mod", "build.zig.zon", "pom.xml", "build.gradle", "bench.nimble" };

/// One source file of `n` import units in `language`.
pub fn source(a: Allocator, language: []const u8, n: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const is = struct {
        fn f(l: []const u8, name: []const u8) bool {
            return std.mem.eql(u8, l, name);
        }
    }.f;
    if (is(language, "go")) {
        try out.appendSlice(a, "package bench\n\nimport (\n");
        for (0..n) |i| try out.print(a, "\t\"example.com/m{d}\"\n", .{i});
        try out.appendSlice(a, ")\n\n");
    }
    if (is(language, "java")) {
        try out.appendSlice(a, "package bench;\n\n");
        for (0..n) |i| try out.print(a, "import org.bench.m{d}.C{d};\n", .{ i, i });
        try out.appendSlice(a, "\npublic class Big {\n");
    }
    for (0..n) |i| {
        if (is(language, "zig")) {
            try out.print(a, "const m{d} = @import(\"m{d}.zig\");\n// @import(\"fake.zig\")\nconst s{d} = \"@import(\\\"x.zig\\\")\";\nfn f_{d}() u32 {{\n    return {d};\n}}\n", .{ i, i, i, i, i });
        } else if (is(language, "c")) {
            try out.print(a, "#include \"m{d}.h\"\n/* #include \"fake.h\" */\nstatic const char *s{d} = \"#include \\\"x.h\\\"\";\nstatic int f{d}(void) {{ return {d}; }}\n", .{ i, i, i, i });
        } else if (is(language, "javascript")) {
            try out.print(a, "import {{ a{d} }} from './m{d}';\n// import x from './fake'\nconst s{d} = \"import y from './z'\";\nexport function f{d}(): number {{ return {d}; }}\n", .{ i, i, i, i, i });
        } else if (is(language, "python")) {
            try out.print(a, "import pkg.m{d}\n# import fake\ns{d} = \"import fake\"\ndef f{d}():\n    return {d}\n", .{ i, i, i, i });
        } else if (is(language, "go")) {
            try out.print(a, "// import \"fake\"\nvar s{d} = \"import \\\"x\\\"\"\n\nfunc f{d}() int {{ return {d} }}\n", .{ i, i, i });
        } else if (is(language, "rust")) {
            try out.print(a, "use crate::m{d}::Item{d};\n// use fake::x;\nconst S{d}: &str = \"use x::y;\";\nfn f{d}() -> u32 {{ {d} }}\n", .{ i, i, i, i, i });
        } else if (is(language, "nim")) {
            try out.print(a, "import m{d}\n# import fake\nlet s{d} = \"import x\"\nproc f{d}(): int = {d}\n", .{ i, i, i, i });
        } else if (is(language, "java")) {
            try out.print(a, "    // import fake.Thing;\n    String s{d} = \"import x.y;\";\n    int f{d}() {{ return {d}; }}\n", .{ i, i, i });
        }
    }
    if (is(language, "java")) try out.appendSlice(a, "}\n");
    return out.items;
}

/// TypeScript with each import kind: one static, five type-only, one
/// dynamic, and a commented-out import, per unit.
pub fn kinds(a: Allocator, n: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (0..n) |i| try out.print(a,
        \\import {{ a{d} }} from './m{d}';
        \\import type {{ T{d} }} from './t{d}';
        \\export type {{ U{d} }} from './u{d}';
        \\import {{ type V{d}, type W{d} }} from './v{d}';
        \\const d{d} = import('./d{d}');
        \\let x{d}: import('./x{d}').X;
        \\type Y{d} = typeof import('./y{d}');
        \\// import type {{ Z }} from './fake'
        \\
    , .{ i, i, i, i, i, i, i, i, i, i, i, i, i, i, i });
    return out.items;
}

pub fn manifest(a: Allocator, name: []const u8, n: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const eql = std.mem.eql;
    if (eql(u8, name, "package.json")) {
        try out.appendSlice(a, "{\n  \"name\": \"bench\",\n  \"version\": \"1.0.0\",\n  \"dependencies\": {\n");
        for (0..n) |i| try out.print(a, "{s}    \"d{d}\": \"^1.{d}.0\"", .{ if (i == 0) "" else ",\n", i, i });
        try out.appendSlice(a, "\n  }\n}\n");
    } else if (eql(u8, name, "Cargo.toml")) {
        try out.appendSlice(a, "[package]\nname = \"bench\"\nversion = \"0.1.0\"\n\n[dependencies]\n");
        for (0..n) |i| try out.print(a, "d{d} = \"1.{d}\"\n", .{ i, i });
    } else if (eql(u8, name, "pyproject.toml")) {
        try out.appendSlice(a, "[project]\nname = \"bench\"\nversion = \"1.0\"\ndependencies = [\n");
        for (0..n) |i| try out.print(a, "    \"d{d}>=1.{d}\",\n", .{ i, i });
        try out.appendSlice(a, "]\n");
    } else if (eql(u8, name, "go.mod")) {
        try out.appendSlice(a, "module example.com/bench\n\ngo 1.22\n\nrequire (\n");
        for (0..n) |i| try out.print(a, "\texample.com/d{d} v1.{d}.0\n", .{ i, i });
        try out.appendSlice(a, ")\n");
    } else if (eql(u8, name, "build.zig.zon")) {
        try out.appendSlice(a, ".{\n    .name = .bench,\n    .version = \"0.0.0\",\n    .fingerprint = 0x1234567890abcdef,\n    .dependencies = .{\n");
        for (0..n) |i| try out.print(a, "        .d{d} = .{{\n            .url = \"https://example.com/d{d}.tar.gz\",\n            .hash = \"d{d}-1.0.0-AAAAAAAA\",\n        }},\n", .{ i, i, i });
        try out.appendSlice(a, "    },\n    .paths = .{\"\"},\n}\n");
    } else if (eql(u8, name, "pom.xml")) {
        try out.appendSlice(a, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<project>\n  <modelVersion>4.0.0</modelVersion>\n  <groupId>org.bench</groupId>\n  <artifactId>bench</artifactId>\n  <version>1.0</version>\n  <dependencies>\n");
        for (0..n) |i| try out.print(a, "    <dependency>\n      <groupId>org.d{d}</groupId>\n      <artifactId>d{d}</artifactId>\n      <version>1.{d}</version>\n    </dependency>\n", .{ i, i, i });
        try out.appendSlice(a, "  </dependencies>\n</project>\n");
    } else if (eql(u8, name, "build.gradle")) {
        try out.appendSlice(a, "plugins {\n    id 'java'\n}\n\ndependencies {\n");
        for (0..n) |i| try out.print(a, "    implementation 'org.d{d}:d{d}:1.{d}'\n", .{ i, i, i });
        try out.appendSlice(a, "}\n");
    } else if (eql(u8, name, "bench.nimble")) {
        try out.appendSlice(a, "version = \"1.0.0\"\nauthor = \"bench\"\n\n");
        for (0..n) |i| try out.print(a, "requires \"d{d} >= 1.{d}\"\n", .{ i, i });
    } else return error.UnknownManifest;
    return out.items;
}

/// `count` pages in groups of ten; five sibling links each, plus links in
/// fenced code and comments that are not links.
fn markdown(w: Writer, prefix: []const u8, count: usize) !void {
    for (0..count) |i| {
        const g = i / 10;
        const m = i % 10;
        var text: std.ArrayList(u8) = .empty;
        try text.print(w.a, "# Page {d}\n\n" ++ comment16 ++ "\n\n", .{i});
        for (1..6) |k| try text.print(w.a, "See [page {d}](m{d}.md) and read on.\n", .{ k, (m + k) % 10 });
        try text.appendSlice(w.a, "\n```\n[not a link](m0.md)\n```\n\n<!-- [hidden](m1.md) -->\n");
        try w.write(try w.a.print("{s}/d{d}/m{d}.md", .{ prefix, g, m }), text.items);
    }
}

/// An importable package for import-linter: pkg.gN.fM imports pkg.gN.f(M-1).
fn pythonPackage(w: Writer, prefix: []const u8, count: usize) !void {
    try w.write(try w.a.print("{s}/pkg/__init__.py", .{prefix}), "");
    for (0..count) |i| {
        const g = i / 10;
        const m = i % 10;
        if (m == 0) try w.write(try w.a.print("{s}/pkg/g{d}/__init__.py", .{ prefix, g }), "");
        const body = if (m != 0) try w.a.print("import pkg.g{d}.f{d}\n", .{ g, m - 1 }) else "";
        try w.write(try w.a.print("{s}/pkg/g{d}/f{d}.py", .{ prefix, g, m }), try std.mem.concat(w.a, u8, &.{ body, "# " ++ comment16 ++ "\ntext = \"import pkg.fake\"\n" }));
    }
}

/// tpkg.gN.fM imports the module before it, and under `if TYPE_CHECKING:`
/// the module after it.
fn typingPackage(w: Writer, prefix: []const u8, count: usize) !void {
    try w.write(try w.a.print("{s}/tpkg/__init__.py", .{prefix}), "");
    for (0..count) |i| {
        const g = i / 10;
        const m = i % 10;
        if (m == 0) try w.write(try w.a.print("{s}/tpkg/g{d}/__init__.py", .{ prefix, g }), "");
        var body: std.ArrayList(u8) = .empty;
        try body.appendSlice(w.a, "from typing import TYPE_CHECKING\n");
        if (m != 0) try body.print(w.a, "import tpkg.g{d}.f{d}\n", .{ g, m - 1 });
        if (m < 9) try body.print(w.a, "if TYPE_CHECKING:\n    import tpkg.g{d}.f{d}\n", .{ g, m + 1 });
        try body.appendSlice(w.a, "# " ++ comment16 ++ "\n");
        try w.write(try w.a.print("{s}/tpkg/g{d}/f{d}.py", .{ prefix, g, m }), body.items);
    }
}

/// js/gN/fM.ts imports the file before it in its folder, and each f0 the
/// f5 of folder (N - 1) / 2: dependencies inside and across folders, in
/// chains no deeper than a balanced tree, so a tool that searches cycles
/// recursively does not run out of stack on hundreds of folders.
fn typescriptTree(w: Writer, prefix: []const u8, count: usize) !void {
    for (0..count) |i| {
        const g = i / 10;
        const m = i % 10;
        const body = if (m != 0)
            try w.a.print("import './f{d}';\n", .{m - 1})
        else if (g != 0)
            try w.a.print("import '../g{d}/f5';\n", .{(g - 1) / 2})
        else
            "";
        try w.write(try w.a.print("{s}/js/g{d}/f{d}.ts", .{ prefix, g, m }), try std.mem.concat(w.a, u8, &.{ body, "// " ++ comment16 ++ "\nexport const text = \"import './fake'\";\n" }));
    }
}

pub const Fixture = struct {
    kind: []const u8,
    name: []const u8,
    size: Size,
    /// Absolute.
    path: []const u8,
};

/// Every per-operation fixture under `w.root`; smoke keeps only the small
/// size. With `w.enabled` off, only the paths.
pub fn operations(w: Writer, smoke: bool) ![]const Fixture {
    const a = w.a;
    var files: std.ArrayList(Fixture) = .empty;
    for (languages) |entry| {
        const language = entry[0];
        for (sizes) |size| {
            if (smoke and size != .small) continue;
            const sub = if (std.mem.eql(u8, language, "java"))
                try a.print("imports/{s}/{s}/Big.java", .{ language, @tagName(size) })
            else
                try a.print("imports/{s}/{s}{s}", .{ language, @tagName(size), entry[1] });
            try w.write(sub, try source(a, language, importCount(size)));
            try files.append(a, .{ .kind = "imports", .name = language, .size = size, .path = try std.Io.Dir.path.join(a, &.{ w.root, sub }) });
        }
    }
    for (sizes) |size| {
        if (smoke and size != .small) continue;
        const sub = try a.print("kinds/javascript/{s}.ts", .{@tagName(size)});
        try w.write(sub, try kinds(a, importCount(size)));
        try files.append(a, .{ .kind = "kinds", .name = "javascript", .size = size, .path = try std.Io.Dir.path.join(a, &.{ w.root, sub }) });
    }
    for (manifests) |name| {
        for (sizes) |size| {
            if (smoke and size != .small) continue;
            const sub = try a.print("manifests/{s}/{s}", .{ @tagName(size), name });
            try w.write(sub, try manifest(a, name, manifestCount(size)));
            try files.append(a, .{ .kind = "manifests", .name = name, .size = size, .path = try std.Io.Dir.path.join(a, &.{ w.root, sub }) });
        }
    }
    const count: usize = if (smoke) 10 else 5000;
    try markdown(w, "markdown", count);
    try pythonPackage(w, "python", count);
    try typescriptTree(w, "typescript", if (smoke) 30 else 5000);
    try typingPackage(w, "typing", count);
    return files.items;
}

pub fn find(files: []const Fixture, kind: []const u8, name: []const u8, size: Size) ?[]const u8 {
    for (files) |f| if (std.mem.eql(u8, f.kind, kind) and std.mem.eql(u8, f.name, name) and f.size == size) return f.path;
    return null;
}

/// A digest of every file under `root`, name and bytes, in sorted order:
/// what the generator tests pin.
fn treeDigest(a: Allocator, io: Io, root: []const u8) ![64]u8 {
    var dir = try Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(a);
    defer walker.deinit();
    var names: std.ArrayList([]const u8) = .empty;
    // Slash-separated on every host, so the digest is one value everywhere.
    while (try walker.next(io)) |entry| if (entry.kind == .file) {
        const name = try a.dupe(u8, entry.path);
        std.mem.replaceScalar(u8, name, '\\', '/');
        try names.append(a, name);
    };
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    for (names.items) |name| {
        digest.update(name);
        digest.update(&.{0});
        digest.update(try dir.readFileAlloc(io, name, a, .unlimited));
        digest.update(&.{0});
    }
    var hex: [64]u8 = undefined;
    _ = try std.mem.print(&hex, "{x}", .{&digest.finalResult()});
    return hex;
}

/// `fixtures <synthetic|operations> <root> [--smoke]`: writes one set under
/// `root`. `--smoke` writes the smallest sizes only, and `--smoke` alone
/// writes both under the working directory.
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--smoke")) {
        const root = try std.Io.Dir.cwd().realPathFileAlloc(init.io, ".", a);
        _ = try synthetic(.{ .io = init.io, .a = a, .root = try std.Io.Dir.path.join(a, &.{ root, "corpus" }) }, 10);
        _ = try operations(.{ .io = init.io, .a = a, .root = try std.Io.Dir.path.join(a, &.{ root, "ops" }) }, true);
        return;
    }
    if (args.len < 3) return error.ExpectedKindAndRoot;
    const smoke = args.len > 3 and std.mem.eql(u8, args[3], "--smoke");
    const w: Writer = .{ .io = init.io, .a = a, .root = args[2] };
    if (std.mem.eql(u8, args[1], "synthetic")) {
        // The code files' total bytes.
        var buffer: [64]u8 = undefined;
        var stdout = std.Io.File.stdout().writerStreaming(init.io, &buffer);
        try stdout.interface.print("{d}\n", .{try synthetic(w, if (smoke) 10 else 5000)});
        try stdout.interface.flush();
    } else {
        _ = try operations(w, smoke);
    }
}

// Digests of the smoke sizes' bytes, so a change to the inputs is seen
// before it moves a measurement.
test "the synthetic corpus keeps its bytes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const total = try synthetic(.{ .io = io, .a = a, .root = root }, 10);
    try std.testing.expectEqual(@as(usize, 61370), total);
    const digest = try treeDigest(a, io, root);
    try std.testing.expectEqualStrings(synthetic_digest, &digest);
}

test "the per-operation fixtures keep their bytes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const files = try operations(.{ .io = io, .a = a, .root = root }, true);
    try std.testing.expectEqual(@as(usize, 8 + 1 + 8), files.len);
    try std.testing.expect(find(files, "imports", "java", .small) != null);
    const digest = try treeDigest(a, io, root);
    try std.testing.expectEqualStrings(operations_digest, &digest);
    // Paths only: nothing written.
    const listed = try operations(.{ .io = io, .a = a, .root = "/nonexistent", .enabled = false }, false);
    try std.testing.expectEqual(@as(usize, 3 * 17), listed.len);
}

const synthetic_digest = "b11cefcae9424790fd22c42b6c5e000c6addc0871d4df3bd31cfbc64883d13b6";
const operations_digest = "c50dc69f5ef10f80ec6063cd67cf5f92ed7f27482a4c02e56a5a0f181d173556";
