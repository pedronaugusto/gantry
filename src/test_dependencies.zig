const std = @import("std");
const g = @import("gantry.zig");
const f = @import("test_support.zig");
const a = std.testing.allocator;
const eq = std.testing.expectEqual;

/// Undeclared packages, then unused declarations, as `want` spells them.
fn expectFindings(graph: *const g.Graph, rule: g.rules.DependencyRule, undeclared: []const []const u8, unused: []const []const u8) !void {
    const findings = try graph.check(a, .{ .dependencies = &.{rule} });
    defer g.rules.free(a, findings);
    var got_undeclared: std.ArrayList([]const u8) = .empty;
    defer got_undeclared.deinit(a);
    var got_unused: std.ArrayList([]const u8) = .empty;
    defer got_unused.deinit(a);
    for (findings) |finding| switch (finding.reason) {
        .undeclared => {
            try std.testing.expect(finding.reference != null and finding.path != null);
            try got_undeclared.append(a, finding.package.?);
        },
        .unused => try got_unused.append(a, finding.dependency.?.name),
        else => return error.TestUnexpectedResult,
    };
    try eq(undeclared.len, got_undeclared.items.len);
    for (undeclared, got_undeclared.items) |want, got| try std.testing.expectEqualStrings(want, got);
    try eq(unused.len, got_unused.items.len);
    for (unused, got_unused.items) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "npm imports join package.json by package name, builtins and paths aside" {
    var graph = try (f.Fixture{ .items = &.{
        .{ .path = "web/package.json", .text = "{\"dependencies\":{\"lodash\":\"1\",\"react\":\"1\",\"left-pad\":\"1\",\"@scope/used\":\"1\"},\"devDependencies\":{\"typescript\":\"5\"}}" },
        .{ .path = "web/src/a.ts", .text = "import x from 'lodash/fp'; import type {T} from '@scope/pkg/sub'; import fs from 'node:fs'; import p from 'path/posix'; import b from './b'; import i from '#internal'; import h from '~/alias'; import r from 'react'; import u from '@scope/used'; const m = import('chalk');" },
        .{ .path = "web/src/b.ts", .text = "" },
        .{ .path = "other.ts", .text = "import z from 'zod';" },
    } }).scan(a, .{});
    defer graph.deinit();
    // other.ts has no package.json above it: nothing to judge it by.
    try expectFindings(&graph, .{ .name = "deps" }, &.{ "@scope/pkg", "chalk" }, &.{"left-pad"});
    try expectFindings(&graph, .{ .name = "deps", .unused = &.{ .runtime, .development }, .ignore = &.{"chalk"} }, &.{"@scope/pkg"}, &.{ "left-pad", "typescript" });
    try expectFindings(&graph, .{ .name = "deps", .undeclared = false, .unused = &.{} }, &.{}, &.{});
    // Files outside `from` neither import nor make their manifest's declarations unused.
    try expectFindings(&graph, .{ .name = "deps", .from = "elsewhere/**" }, &.{}, &.{});
}

test "Python imports join pyproject by normalized name, with names for other spellings" {
    var graph = try (f.Fixture{ .items = &.{
        .{ .path = "pyproject.toml", .text = "[project]\nname='p'\ndependencies=['PyYAML>=1','requests','Flask_Login','unused-thing']\n[dependency-groups]\ntest=['pytest']\n" },
        .{ .path = "pkg/m.py", .text = "import yaml\nfrom requests.adapters import X\nimport os.path\nimport numpy\nimport flask_login\nfrom . import sibling\n" },
    } }).scan(a, .{});
    defer graph.deinit();
    try expectFindings(&graph, .{ .name = "deps" }, &.{ "yaml", "numpy" }, &.{ "PyYAML", "unused-thing" });
    try expectFindings(&graph, .{ .name = "deps", .names = &.{.{ .import = "yaml", .package = "pyyaml" }} }, &.{"numpy"}, &.{"unused-thing"});
}

test "Rust crates join Cargo.toml through use paths, extern crates and paths in code" {
    var graph = try (f.Fixture{ .items = &.{
        .{ .path = "Cargo.toml", .text = "[package]\nname = \"p\"\n[dependencies]\nserde = \"1\"\nserde-json = \"1\"\ntokio = \"1\"\nunused_crate = \"1\"\n[dev-dependencies]\nproptest = \"1\"\n" },
        .{ .path = "src/lib.rs", .text =
        \\use serde::Deserialize;
        \\use std::io;
        \\use crate::util::Thing;
        \\mod util;
        \\mod local { pub fn f() {} }
        \\use local::f;
        \\extern crate libc;
        \\#[tokio::main]
        \\async fn main() { let s = serde_json::to_string(&1); io::stdout(); Vec::<u8>::new(); }
        },
        .{ .path = "src/util.rs", .text = "pub struct Thing; fn g() { rand::random::<u8>(); }" },
    } }).scan(a, .{});
    defer graph.deinit();
    try expectFindings(&graph, .{ .name = "deps" }, &.{ "libc", "rand" }, &.{"unused_crate"});
}

test "Go imports join go.mod by the longest module path, indirect requirements aside" {
    var graph = try (f.Fixture{ .items = &.{
        .{ .path = "go.mod", .text = "module example.org/app\nrequire (\n\tgithub.com/x/y v1.0.0\n\tgithub.com/x/y/v2 v2.0.0\n\tgithub.com/z/w v1.0.0 // indirect\n\tgithub.com/q/r v1.0.0\n)\n" },
        .{ .path = "main.go", .text = "package main\nimport (\n\"fmt\"\n\"C\"\n\"github.com/x/y/v2/pkg\"\n\"example.net/undeclared/pkg\"\n\"github.com/q/r\"\n)\n" },
    } }).scan(a, .{});
    defer graph.deinit();
    try expectFindings(&graph, .{ .name = "deps" }, &.{"example.net/undeclared/pkg"}, &.{"github.com/x/y"});
    for (graph.dependencies()) |dep| if (std.mem.eql(u8, dep.name, "github.com/z/w")) try std.testing.expectEqualStrings("indirect", dep.group);
}

test "Zig, Nim and Java imports join their manifests" {
    var graph = try (f.Fixture{ .items = &.{
        .{ .path = "z/build.zig.zon", .text = ".{ .name = .p, .version = \"0.0.0\", .dependencies = .{ .visor = .{ .path = \"v\" }, .chronicle = .{ .path = \"c\" } }, .paths = .{\"\"} }" },
        .{ .path = "z/src/main.zig", .text = "const s = @import(\"std\"); const v = @import(\"visor\"); const l = @import(\"lookout\"); const u = @import(\"missing.zig\"); const b = @import(\"builtin\");" },
        .{ .path = "n/p.nimble", .text = "requires \"nim >= 2.0\", \"foo\", \"bar\"\n" },
        .{ .path = "n/a.nim", .text = "import strutils, std/os, pkg/foo, baz/sub\n" },
        .{ .path = "j/pom.xml", .text = "<project><dependencies><dependency><groupId>com.google.guava</groupId><artifactId>guava</artifactId><version>1</version></dependency><dependency><groupId>org.apache.commons</groupId><artifactId>commons-lang3</artifactId><version>3</version></dependency><dependency><groupId>junit</groupId><artifactId>junit</artifactId><version>4</version><scope>test</scope></dependency></dependencies></project>" },
        .{ .path = "j/src/A.java", .text = "package a;\nimport com.google.common.collect.ImmutableList;\nimport org.apache.commons.lang3.StringUtils;\nimport java.util.Map;\nimport javax.swing.JFrame;\nimport javax.inject.Inject;\n" },
    } }).scan(a, .{});
    defer graph.deinit();
    try expectFindings(&graph, .{ .name = "deps", .from = "z/**" }, &.{"lookout"}, &.{"chronicle"});
    try expectFindings(&graph, .{ .name = "deps", .from = "n/**" }, &.{"baz"}, &.{"bar"});
    try expectFindings(&graph, .{ .name = "deps", .from = "j/**" }, &.{ "com.google.common.collect", "javax.inject" }, &.{"com.google.guava:guava"});
    try expectFindings(&graph, .{ .name = "deps", .from = "j/**", .names = &.{.{ .import = "com.google.common", .package = "guava" }}, .ignore = &.{"javax.*"} }, &.{}, &.{});
}

test "a dependency rule needs the manifests a scan read" {
    var graph = try (f.Fixture{ .items = &.{
        .{ .path = "package.json", .text = "{\"dependencies\":{\"lodash\":\"1\"}}" },
        .{ .path = "a.ts", .text = "import x from 'lodash';" },
    } }).scan(a, .{ .manifests = false });
    defer graph.deinit();
    try std.testing.expectError(error.UnscannedManifests, graph.check(a, .{ .dependencies = &.{.{ .name = "deps" }} }));
    // A manifest the reader could not read governs nothing.
    var unread = try (f.Fixture{ .items = &.{
        .{ .path = "package.json", .text = null },
        .{ .path = "a.ts", .text = "import x from 'lodash';" },
    } }).scan(a, .{});
    defer unread.deinit();
    try expectFindings(&unread, .{ .name = "deps" }, &.{}, &.{});
}
