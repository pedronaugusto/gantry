const std = @import("std");
const g = @import("gantry.zig");
const f = @import("test_support.zig");
const a = std.testing.allocator;
const eq = std.testing.expectEqual;
fn dep(deps: []const g.Dependency, name: []const u8, source: []const u8) !void {
    for (deps) |d| if (std.mem.eql(u8, d.name, name)) {
        try std.testing.expectEqualStrings(source, d.source);
        return;
    };
    return error.TestMissingDependency;
}
test "fixture: manifest fixtures name dependencies and their sources from temp files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const items = [_]f.Item{
        .{ .path = "build.zig.zon", .text =
        \\.{
        \\ .name = .fixture,
        \\ .dependencies = .{
        \\  .strand = .{ .url = "git+https://github.com/me/strand#abc", .hash = "strand-0.7.0-x" },
        \\  .@"lib-x" = .{ .path = "../lib-x" },
        \\ },
        \\ .paths = .{ "build.zig", "src" },
        \\}
        },
        .{ .path = "package.json", .text = "{\"dependencies\":{\"astro\":\"^5.0.0\",\"kit\":\"github:me/kit\"},\"devDependencies\":{\"local\":\"file:../local\"}}" },
        .{ .path = "Cargo.toml", .text = "[package]\nname='x'\n[dependencies]\nserde='1'\nengine={git='https://github.com/me/engine', branch='main'}\n[profile.release]\nlto=true" },
        .{ .path = "go.mod", .text = "module example.com/me/cli\nrequire github.com/me/core v1.2.0\nrequire (\n golang.org/x/sys v0.1.0 // indirect\n)" },
        .{ .path = "pyproject.toml", .text = "[project]\nname='tool'\ndependencies=[\n 'requests>=2',\n 'mylib @ git+https://github.com/me/mylib',\n]" },
    };
    var paths: [items.len][]const u8 = undefined;
    for (items, &paths) |item, *path| {
        path.* = item.path;
        try tmp.dir.writeFile(io, .{ .sub_path = item.path, .data = item.text.? });
    }
    var graph = try g.scan(a, &paths, g.DirReader{ .io = io, .dir = tmp.dir }, g.DirReader.read, .{});
    defer graph.deinit();
    try eq(11, graph.dependencies().len);
    try dep(graph.dependencies(), "strand", "git+https://github.com/me/strand#abc");
    try dep(graph.dependencies(), "lib-x", "../lib-x");
    try dep(graph.dependencies(), "astro", "");
    try dep(graph.dependencies(), "kit", "github:me/kit");
    try dep(graph.dependencies(), "local", "file:../local");
    try dep(graph.dependencies(), "serde", "");
    try dep(graph.dependencies(), "engine", "https://github.com/me/engine");
    try dep(graph.dependencies(), "github.com/me/core", "github.com/me/core");
    try dep(graph.dependencies(), "golang.org/x/sys", "golang.org/x/sys");
    try dep(graph.dependencies(), "requests", "");
    try dep(graph.dependencies(), "mylib", "git+https://github.com/me/mylib");
}
test "package JSON retains all declaration groups and requirements" {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const deps = try g.manifests.parse(arena.allocator(), "web/package.json", "{\"dependencies\":{\"a\":\"1\"},\"devDependencies\":{\"a\":\"2\"},\"peerDependencies\":{\"b\":\"*\"},\"optionalDependencies\":{\"c\":\"file:../c\"}}");
    try eq(4, deps.len);
    try std.testing.expectEqualStrings("2", deps[1].requirement);
    try std.testing.expectEqualStrings("optionalDependencies", deps[3].group);
}
test "ZON comments nested braces quoted names and misleading strings" {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const deps = try g.manifests.parse(arena.allocator(), "build.zig.zon",
        \\.{
        \\ // .dependencies = .{ .fake = .{ .path = "fake" } }
        \\ .note = ".dependencies = .{ .fake = .{} }",
        \\ .dependencies=.{ .@"a-b"=.{ .url="git+https://x/{a}", .lazy=true }, },
        \\}
    );
    try eq(1, deps.len);
    try dep(deps, "a-b", "git+https://x/{a}");
}
test "Cargo workspace target dev build dependencies and separate dependency tables" {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const deps = try g.manifests.parse(arena.allocator(), "crates/x/Cargo.toml",
        \\[dependencies]
        \\serde = { version = "1", features = ["derive"] }
        \\shared = { workspace = true }
        \\[dev-dependencies]
        \\test-kit = "2"
        \\[build-dependencies]
        \\builder = { path = "../builder" }
        \\[workspace.dependencies]
        \\base = { git = "https://x/base" }
        \\[target.'cfg(unix)'.dependencies]
        \\unix = "3"
        \\[dependencies.long]
        \\version = "4"
        \\git = "https://x/long"
        \\[package.metadata]
        \\fake = "5"
    );
    try eq(7, deps.len);
    try dep(deps, "shared", "workspace");
    try dep(deps, "builder", "../builder");
    try dep(deps, "base", "https://x/base");
    try dep(deps, "long", "https://x/long");
    try std.testing.expectEqualStrings("1", deps[0].requirement);
}
test "Python requirements extras markers direct URLs optional and poetry groups" {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const deps = try g.manifests.parse(arena.allocator(), "pyproject.toml",
        \\[project]
        \\dependencies = ["requests[security]>=2; python_version > '3.8'", "lib @ https://x/lib ; os_name == 'posix'"]
        \\[project.optional-dependencies]
        \\test = ["pytest>=8"]
        \\[dependency-groups]
        \\lint = ["ruff"]
        \\[tool.poetry.dependencies]
        \\python = ">=3.12"
        \\local = { path = "../local" }
        \\[tool.poetry.group.dev.dependencies]
        \\other = "2"
    );
    try eq(6, deps.len);
    try dep(deps, "requests", "");
    try dep(deps, "lib", "https://x/lib");
    try dep(deps, "pytest", "");
    try dep(deps, "local", "../local");
}
test "dependency-looking text outside supported manifest sections stays out" {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const deps = try g.manifests.parse(arena.allocator(), "pyproject.toml", "[tool.other]\ndependencies=['fake']\n# dependencies=['fake']\n[project]\nname='x'");
    try eq(0, deps.len);
    const cargo = try g.manifests.parse(arena.allocator(), "Cargo.toml", "[package]\nname='x'\n# [dependencies]\n# fake='1'\n[profile.release]\nlto=true");
    try eq(0, cargo.len);
}
test "malformed dependency declarations fail rather than reporting an empty success" {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    for ([_]struct { path: []const u8, text: []const u8 }{
        .{ .path = "package.json", .text = "{" },
        .{ .path = "package.json", .text = "{\"dependencies\":[]}" },
        .{ .path = "package.json", .text = "{\"dependencies\":{\"x\":null}}" },
        .{ .path = "Cargo.toml", .text = "[dependencies]\nx = [" },
        .{ .path = "pyproject.toml", .text = "[project]\ndependencies = 3" },
        .{ .path = "go.mod", .text = "require (\nx v1" },
        .{ .path = "build.zig.zon", .text = ".{ .dependencies=.{ .x=.{ .path=\"x\" }" },
    }) |case| try std.testing.expectError(error.InvalidManifest, g.manifests.parse(arena.allocator(), case.path, case.text));
    try std.testing.expectError(error.UnsupportedManifest, g.manifests.parse(arena.allocator(), "lockfile", ""));
}
test "manifest dependencies are separate from internal graph and scan order deterministic" {
    const fixture: f.Fixture = .{ .items = &.{
        .{ .path = "package.json", .text = "{\"dependencies\":{\"z\":\"1\",\"a\":\"2\"}}" },
        .{ .path = "main.ts", .text = "import './x'; import 'z';" },
        .{ .path = "x.ts" },
    } };
    var graph = try fixture.scan(a, .{});
    defer graph.deinit();
    var other = try g.scan(a, &.{ "x.ts", "main.ts", "package.json" }, fixture, f.Fixture.read, .{});
    defer other.deinit();
    try eq(1, graph.edges().len);
    try eq(2, graph.dependencies().len);
    try std.testing.expectEqualStrings("a", graph.dependencies()[0].name);
    try std.testing.expectEqualDeep(graph.dependencies(), other.dependencies());
    try std.testing.expectEqualDeep(graph.references(), other.references());
}

test "dependency group inclusion and TOML literal backslashes are not invented declarations" {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const deps = try g.manifests.parse(arena.allocator(), "pyproject.toml", "[dependency-groups]\nall=[{ include-group = 'test' }, 'ruff']\n[tool.poetry.dependencies]\nlocal={path='dir\\name'}");
    try eq(2, deps.len);
    try dep(deps, "ruff", "");
    try dep(deps, "local", "dir\\name");
}

test "ZON selects root dependencies after nested blocks and decodes field names" {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const deps = try g.manifests.parse(arena.allocator(), "build.zig.zon",
        \\.{
        \\ .other = .{ .dependencies = .{ .ghost = .{ .path = "../ghost" } } },
        \\ .@"depend\x65ncies" = .{ .@"lib\x2dx" = .{ .@"pa\x74h" = "../real" } },
        \\}
    );
    try eq(1, deps.len);
    try dep(deps, "lib-x", "../real");
    const nested = try g.manifests.parse(arena.allocator(), "build.zig.zon", ".{ .other = .{ .dependencies = .{ .ghost = .{ .path = \"../ghost\" } } } }");
    try eq(0, nested.len);
}

test "ZON validates the whole document before extracting declarations" {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    for ([_][]const u8{
        ".{ .dependencies = .{ .ghost = .{ .path = \"../ghost\" } }, .other = }",
        ".{ .dependencies = .{} } trailing",
        ".{ .dependencies = .{} } .{}",
        ".{ .note = @import(\"x\"), .dependencies = .{} }",
        ".{ .note = \"\\q\", .dependencies = .{} }",
        ".{ .note = 1 + 2, .dependencies = .{} }",
        ".{ .note = 1, .note = 2, .dependencies = .{} }",
        ".{ .dependencies = .{} }\x00",
        "",
        "42",
        ".{ 1, 2 }",
    }) |text| try std.testing.expectError(error.InvalidManifest, g.manifests.parse(arena.allocator(), "build.zig.zon", text));
}

test "ZON rejects malformed dependency field shapes" {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    for ([_][]const u8{
        ".{ .dependencies = 42 }",
        ".{ .dependencies = .{ .x = .{ .lazy = 42 } } }",
        ".{ .dependencies = .{ .x = .{ .url = \"x\", .path = \"x\" } } }",
        ".{ .dependencies = .{ .x = .{ .path = false } } }",
        ".{ .dependencies = .{ .x = .{ .url = .{ \"x\" } } } }",
        ".{ .dependencies = .{ .x = .{ .hash = 42 } } }",
        ".{ .dependencies = .{ .x = \"x\" } }",
        ".{ .dependencies = .{ .x = .{ .path = \"x\" }, .x = .{ .path = \"y\" } } }",
    }) |text| try std.testing.expectError(error.InvalidManifest, g.manifests.parse(arena.allocator(), "build.zig.zon", text));
}

test "ZON decodes multiline declaration strings and ignores nested metadata" {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const deps = try g.manifests.parse(arena.allocator(), "pkg/build.zig.zon",
        \\.{
        \\ .name = .demo, .fingerprint = 0x1234, .minimum_zig_version = "0.16.0",
        \\ .paths = .{ "src", "build.zig" },
        \\ .dependencies = .{
        \\   .lib = .{
        \\     .url =
        \\       \\https://host/lib
        \\     ,
        \\     .hash = "lib-0.1.0-\x61", .lazy = true,
        \\     .metadata = .{ .path = "fake", .hash = "fake" },
        \\   },
        \\ },
        \\}
    );
    try eq(1, deps.len);
    try dep(deps, "lib", "https://host/lib");
    try std.testing.expectEqualStrings("pkg/build.zig.zon", deps[0].manifest);
    try std.testing.expectEqualStrings("lib-0.1.0-a", deps[0].requirement);
    const empty = try g.manifests.parse(arena.allocator(), "build.zig.zon", ".{} // empty\n");
    try eq(0, empty.len);
}

test "ZON scan propagates a malformed tail instead of returning a partial graph" {
    const result = (f.Fixture{ .items = &.{
        .{ .path = "build.zig.zon", .text = ".{ .dependencies = .{ .x = .{ .path = \"x\" } }, .tail = }" },
        .{ .path = "a.zig", .text = "const b = @import(\"b.zig\");" },
        .{ .path = "b.zig" },
    } }).scan(a, .{});
    if (result) |value| {
        var graph = value;
        defer graph.deinit();
        return error.TestExpectedError;
    } else |err| try eq(error.InvalidManifest, err);
}

fn zonAllocations(alloc: std.mem.Allocator) !void {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    var text = ".{ .dependencies = .{ .@\"lib-x\" = .{ .path = \"../lib\" }, .remote = .{ .url = \"https://x\", .hash = \"abc\" } } }".*;
    const deps = try g.manifests.parse(arena.allocator(), "build.zig.zon", &text);
    @memset(&text, ' ');
    try dep(deps, "lib-x", "../lib");
    try dep(deps, "remote", "https://x");
    try eq(2, deps.len);
    try std.testing.expectEqualStrings("abc", deps[1].requirement);
    _ = g.manifests.parse(arena.allocator(), "build.zig.zon", ".{ .dependencies = .{}, .tail = }") catch |err| {
        if (err == error.OutOfMemory) return err;
        try eq(error.InvalidManifest, err);
        return;
    };
    return error.TestExpectedError;
}
test "ZON declarations outlive source and parser storage and release every failed allocation" {
    try std.testing.checkAllAllocationFailures(a, zonAllocations, .{});
}
fn find(deps: []const g.Dependency, name: []const u8) !g.Dependency {
    for (deps) |d| if (std.mem.eql(u8, d.name, name)) return d;
    return error.TestMissingDependency;
}
test "each declaration says where it comes from by the key or form that named it" {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const zon = try g.manifests.parse(aa, "build.zig.zon",
        \\.{
        \\ .dependencies = .{
        \\  .strand = .{ .url = "git+https://github.com/me/strand#abc", .hash = "strand-0.7.0-x" },
        \\  .up = .{ .path = "../up" },
        \\  .here = .{ .path = "./vendor/here" },
        \\  .bare = .{ .path = "vendor/bare" },
        \\  .abs = .{ .path = "/opt/abs" },
        \\ },
        \\}
    );
    try eq(g.Dependency.Origin.remote, (try find(zon, "strand")).origin);
    // a path is a folder however it is written, never a place elsewhere
    for ([_][]const u8{ "up", "here", "bare", "abs" }) |name| try eq(g.Dependency.Origin.local, (try find(zon, name)).origin);

    const npm = try g.manifests.parse(aa, "package.json",
        \\{"dependencies":{"astro":"^5.0.0","tag":"latest","alias":"npm:@scope/x@^1","kit":"github:me/kit#v2","short":"me/short","url":"https://host/x.tgz","git":"git+ssh://git@host/x.git","file":"file:../file","link":"link:../link","rel":"./rel","ws":"workspace:*"}}
    );
    for ([_][]const u8{ "astro", "tag", "alias" }) |name| try eq(g.Dependency.Origin.registry, (try find(npm, name)).origin);
    for ([_][]const u8{ "kit", "short", "url", "git" }) |name| try eq(g.Dependency.Origin.remote, (try find(npm, name)).origin);
    for ([_][]const u8{ "file", "link", "rel" }) |name| try eq(g.Dependency.Origin.local, (try find(npm, name)).origin);
    try eq(g.Dependency.Origin.workspace, (try find(npm, "ws")).origin);

    const cargo = try g.manifests.parse(aa, "Cargo.toml",
        \\[dependencies]
        \\serde = "1"
        \\engine = { git = "https://github.com/me/engine", branch = "main" }
        \\near = { path = "../near" }
        \\shared = { workspace = true }
        \\[dependencies.long]
        \\git = "https://x/long"
        \\[dependencies.inner]
        \\path = "inner"
        \\[dependencies.member]
        \\workspace = true
    );
    try eq(g.Dependency.Origin.registry, (try find(cargo, "serde")).origin);
    try eq(g.Dependency.Origin.remote, (try find(cargo, "engine")).origin);
    try eq(g.Dependency.Origin.remote, (try find(cargo, "long")).origin);
    try eq(g.Dependency.Origin.local, (try find(cargo, "near")).origin);
    try eq(g.Dependency.Origin.local, (try find(cargo, "inner")).origin);
    try eq(g.Dependency.Origin.workspace, (try find(cargo, "shared")).origin);
    try eq(g.Dependency.Origin.workspace, (try find(cargo, "member")).origin);

    const py = try g.manifests.parse(aa, "pyproject.toml",
        \\[project]
        \\dependencies = ["requests>=2", "lib @ git+https://github.com/me/lib.git@v1", "disk @ file:///opt/disk"]
        \\[tool.poetry.dependencies]
        \\near = { path = "../near" }
        \\far = { git = "https://x/far" }
    );
    try eq(g.Dependency.Origin.registry, (try find(py, "requests")).origin);
    try eq(g.Dependency.Origin.remote, (try find(py, "lib")).origin);
    try eq(g.Dependency.Origin.local, (try find(py, "disk")).origin);
    try eq(g.Dependency.Origin.local, (try find(py, "near")).origin);
    try eq(g.Dependency.Origin.remote, (try find(py, "far")).origin);

    const go = try g.manifests.parse(aa, "go.mod", "module m\nrequire github.com/me/core v1.2.0\n");
    try eq(g.Dependency.Origin.remote, go[0].origin);
}
test "a revision is the pin a remote source spells in its own text" {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const zon = try g.manifests.parse(aa, "build.zig.zon",
        \\.{ .dependencies = .{
        \\  .pinned = .{ .url = "git+https://github.com/me/strand#0123abc" },
        \\  .archive = .{ .url = "https://host/archive.tar.gz" },
        \\  .near = .{ .path = "../near#not-a-pin" },
        \\} }
    );
    try std.testing.expectEqualStrings("0123abc", (try find(zon, "pinned")).revision());
    try std.testing.expectEqualStrings("", (try find(zon, "archive")).revision());
    try std.testing.expectEqualStrings("", (try find(zon, "near")).revision());
    const npm = try g.manifests.parse(aa, "web/package.json",
        \\{"dependencies":{"kit":"github:me/kit#v2","git":"git+ssh://git@host/x.git#main","plain":"^1.0.0"}}
    );
    try std.testing.expectEqualStrings("v2", (try find(npm, "kit")).revision());
    try std.testing.expectEqualStrings("main", (try find(npm, "git")).revision());
    try std.testing.expectEqualStrings("", (try find(npm, "plain")).revision());
    const py = try g.manifests.parse(aa, "pyproject.toml",
        \\[project]
        \\dependencies = ["lib @ git+https://github.com/me/lib.git@v1#egg=lib", "ssh @ git+ssh://git@github.com/me/ssh.git", "wheel @ https://host/x-1.0.whl"]
    );
    try std.testing.expectEqualStrings("v1", (try find(py, "lib")).revision());
    // the user before the host is no revision
    try std.testing.expectEqualStrings("", (try find(py, "ssh")).revision());
    try std.testing.expectEqualStrings("", (try find(py, "wheel")).revision());
    const go = try g.manifests.parse(aa, "go.mod", "module m\nrequire github.com/me/core v1.2.0\n");
    try std.testing.expectEqualStrings("", go[0].revision());
}
test "a declaration's scope follows its manifest's groups" {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const Scope = g.Dependency.Scope;
    const npm = try g.manifests.parse(aa, "web/package.json", "{\"dependencies\":{\"a\":\"1\"},\"devDependencies\":{\"b\":\"2\"},\"peerDependencies\":{\"c\":\"*\"},\"optionalDependencies\":{\"d\":\"1\"}}");
    try eq(Scope.runtime, (try find(npm, "a")).scope());
    try eq(Scope.development, (try find(npm, "b")).scope());
    try eq(Scope.runtime, (try find(npm, "c")).scope());
    try eq(Scope.optional, (try find(npm, "d")).scope());
    const cargo = try g.manifests.parse(aa, "Cargo.toml",
        \\[dependencies]
        \\a = "1"
        \\[dev-dependencies]
        \\b = "1"
        \\[build-dependencies]
        \\c = "1"
        \\[target.'cfg(unix)'.dev-dependencies]
        \\d = "1"
        \\[workspace.dependencies]
        \\e = "1"
    );
    try eq(Scope.runtime, (try find(cargo, "a")).scope());
    try eq(Scope.development, (try find(cargo, "b")).scope());
    try eq(Scope.build, (try find(cargo, "c")).scope());
    try eq(Scope.development, (try find(cargo, "d")).scope());
    try eq(Scope.runtime, (try find(cargo, "e")).scope());
    const py = try g.manifests.parse(aa, "pyproject.toml",
        \\[project]
        \\dependencies = ["a"]
        \\[project.optional-dependencies]
        \\extra = ["b"]
        \\[dependency-groups]
        \\lint = ["c"]
        \\[tool.poetry.dependencies]
        \\d = "1"
        \\[tool.poetry.group.dev.dependencies]
        \\e = "1"
        \\[tool.poetry.dev-dependencies]
        \\f = "1"
    );
    try eq(Scope.runtime, (try find(py, "a")).scope());
    try eq(Scope.optional, (try find(py, "b")).scope());
    try eq(Scope.development, (try find(py, "c")).scope());
    try eq(Scope.runtime, (try find(py, "d")).scope());
    try eq(Scope.development, (try find(py, "e")).scope());
    try eq(Scope.development, (try find(py, "f")).scope());
    const zon = try g.manifests.parse(aa, "build.zig.zon", ".{ .dependencies = .{ .a = .{ .path = \"a\" } } }");
    try eq(Scope.runtime, zon[0].scope());
}
test "the manifest names are the ones parse reads" {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    for (g.manifests.names) |name| {
        try std.testing.expect(g.manifests.supported(name));
        const nested = try std.fmt.allocPrint(arena.allocator(), "sub/{s}", .{name});
        try std.testing.expect(g.manifests.supported(nested));
        _ = g.manifests.parse(arena.allocator(), name, "") catch |err| try std.testing.expect(err != error.UnsupportedManifest);
    }
    for (g.manifests.extensions) |extension| {
        const named = try std.fmt.allocPrint(arena.allocator(), "pkg/app{s}", .{extension});
        try std.testing.expect(g.manifests.supported(named));
        _ = g.manifests.parse(arena.allocator(), named, "") catch |err| try std.testing.expect(err != error.UnsupportedManifest);
        try std.testing.expect(!g.manifests.supported(extension));
    }
    try std.testing.expect(!g.manifests.supported("requirements.txt"));
    try std.testing.expect(!g.manifests.supported("app.nimble.bak"));
}
test "Maven dependencies interpolate this file's properties and map their scope" {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const text =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!-- <dependency><groupId>fake</groupId></dependency> -->
        \\<project xmlns="http://maven.apache.org/POM/4.0.0">
        \\  <parent><groupId>org.acme</groupId><version>2.0</version></parent>
        \\  <artifactId>app</artifactId>
        \\  <dependencies>
        \\    <dependency>
        \\      <groupId>org.junit.jupiter</groupId>
        \\      <artifactId>junit-jupiter</artifactId>
        \\      <version>${junit.version}</version>
        \\      <scope>test</scope>
        \\    </dependency>
        \\    <dependency><groupId>${project.groupId}</groupId><artifactId>core</artifactId><version>${project.version}</version></dependency>
        \\    <dependency><groupId>javax.servlet</groupId><artifactId>servlet-api</artifactId><scope>provided</scope></dependency>
        \\    <dependency><groupId>com.x</groupId><artifactId>native</artifactId><version>1</version><scope>system</scope><systemPath>${basedir}/lib/native.jar</systemPath></dependency>
        \\    <dependency><groupId>a&amp;b</groupId><artifactId><![CDATA[c]]></artifactId><optional>true</optional></dependency>
        \\    <dependency><groupId>com.y</groupId><artifactId>lib</artifactId><version>${elsewhere.version}</version></dependency>
        \\  </dependencies>
        \\  <dependencyManagement><dependencies><dependency><groupId>managed</groupId><artifactId>m</artifactId></dependency></dependencies></dependencyManagement>
        \\  <build><plugins><plugin><dependencies><dependency><groupId>plugin</groupId><artifactId>p</artifactId></dependency></dependencies></plugin></plugins></build>
        \\  <properties>
        \\    <junit.version>${junit.major}.10.2</junit.version>
        \\    <junit.major>5</junit.major>
        \\  </properties>
        \\</project>
    ;
    const declared = try g.manifests.read(arena.allocator(), "app/pom.xml", text);
    const deps = declared.dependencies;
    try eq(5, deps.len);
    const Scope = g.Dependency.Scope;
    const junit = try find(deps, "org.junit.jupiter:junit-jupiter");
    try std.testing.expectEqualStrings("5.10.2", junit.requirement);
    try eq(Scope.development, junit.scope());
    const core = try find(deps, "org.acme:core");
    try std.testing.expectEqualStrings("2.0", core.requirement);
    try eq(Scope.runtime, core.scope());
    try std.testing.expectEqualStrings("compile", core.group);
    try eq(Scope.build, (try find(deps, "javax.servlet:servlet-api")).scope());
    const native = try find(deps, "com.x:native");
    try eq(g.Dependency.Origin.local, native.origin);
    try std.testing.expectEqualStrings("./lib/native.jar", native.source);
    try eq(g.Dependency.Origin.registry, (try find(deps, "a&b:c")).origin);
    try eq(1, declared.unsupported.len);
    try eq(g.ImportExpression.maven_dependency, declared.unsupported[0].expression);
    try std.testing.expect(std.mem.startsWith(u8, text[declared.unsupported[0].offset..], "<dependency><groupId>com.y"));
}
test "malformed Maven documents and dependencies fail rather than reporting part of them" {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    for ([_][]const u8{
        "<project><dependencies>",
        "<project></dependencies>",
        "<project><!-- unterminated </project>",
        "<project><dependencies><dependency><artifactId>x</artifactId></dependency></dependencies></project>",
        "<project attr=\"x>",
    }) |text| try std.testing.expectError(error.InvalidManifest, g.manifests.parse(arena.allocator(), "pom.xml", text));
    try eq(0, (try g.manifests.parse(arena.allocator(), "pom.xml", "<settings><dependencies><dependency><groupId>a</groupId><artifactId>b</artifactId></dependency></dependencies></settings>")).len);
}
test "Nimble requirements keep their constraint, origin, revision and scope" {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const declared = try g.manifests.read(arena.allocator(), "app.nimble",
        \\# requires "commented"
        \\version = "0.1.0"
        \\requires "nim >= 2.0.0", "jester >= 0.6",
        \\  "karax#head"
        \\requires("https://github.com/me/lib.git#v1.2 >= 1.0")
        \\when defined(windows):
        \\  requires "winim"
        \\taskRequires "test", "unittest2 ~= 0.2"
        \\feature "web":
        \\  requires "prologue"
        \\requires "after"
        \\let s = "requires \"fake\""
    );
    const deps = declared.dependencies;
    try eq(0, declared.unsupported.len);
    try eq(7, deps.len);
    const Scope = g.Dependency.Scope;
    const jester = try find(deps, "jester");
    try std.testing.expectEqualStrings(">= 0.6", jester.requirement);
    try eq(g.Dependency.Origin.registry, jester.origin);
    try eq(Scope.runtime, jester.scope());
    const karax = try find(deps, "karax");
    try std.testing.expectEqualStrings("#head", karax.requirement);
    try std.testing.expectEqualStrings("head", karax.revision());
    const lib = try find(deps, "https://github.com/me/lib.git");
    try eq(g.Dependency.Origin.remote, lib.origin);
    try std.testing.expectEqualStrings("https://github.com/me/lib.git#v1.2", lib.source);
    try std.testing.expectEqualStrings("v1.2", lib.revision());
    try std.testing.expectEqualStrings(">= 1.0", lib.requirement);
    try eq(Scope.runtime, (try find(deps, "winim")).scope());
    const unittest = try find(deps, "unittest2");
    try std.testing.expectEqualStrings("taskRequires.test", unittest.group);
    try eq(Scope.development, unittest.scope());
    try eq(Scope.optional, (try find(deps, "prologue")).scope());
    try eq(Scope.runtime, (try find(deps, "after")).scope());
}
test "Nimble requirements that are not string literals declare nothing and are kept unsupported" {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const text =
        \\const ver = "1.0"
        \\requires "a", "b >= " & ver
        \\requires someList
        \\taskRequires taskName, "c"
        \\requires "d"
    ;
    const declared = try g.manifests.read(arena.allocator(), "x.nimble", text);
    try eq(1, declared.dependencies.len);
    try std.testing.expectEqualStrings("d", declared.dependencies[0].name);
    try eq(3, declared.unsupported.len);
    for (declared.unsupported) |record| {
        try eq(g.ImportExpression.nimble_requires, record.expression);
        const rest = text[record.offset..];
        try std.testing.expect(std.mem.startsWith(u8, rest, "requires") or std.mem.startsWith(u8, rest, "taskRequires"));
    }
    const fixture: f.Fixture = .{ .items = &.{
        .{ .path = "x.nimble", .text = text },
        .{ .path = "a.nim", .text = "import $name" },
    } };
    var graph = try fixture.scan(a, .{});
    defer graph.deinit();
    try eq(4, graph.unsupported().len);
    try std.testing.expectEqualStrings("a.nim", graph.unsupported()[0].from.?);
    try std.testing.expectEqualStrings("x.nimble", graph.unsupported()[1].from.?);
    var options: g.Options = .{ .strict_imports = true };
    options.kinds = &.{};
    var diagnostic = g.ScanDiagnostic.init(a);
    defer diagnostic.deinit();
    try std.testing.expectError(error.UnsupportedImport, g.scanWithDiagnostic(a, &.{"x.nimble"}, fixture, f.Fixture.read, options, &diagnostic));
    try std.testing.expectEqual(g.ScanDiagnostic.Phase.manifests, diagnostic.failure.?.phase);
    try std.testing.expectEqual(@as(?usize, std.mem.indexOf(u8, text, "requires \"a\"")), diagnostic.failure.?.offset);
}
