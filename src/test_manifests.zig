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
