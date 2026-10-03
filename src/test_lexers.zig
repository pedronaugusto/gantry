const std = @import("std");
const g = @import("gantry.zig");
const expect = std.testing.expect;
const eq = std.testing.expectEqualStrings;
fn check(language: g.Language, source: []const u8, want: []const []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var parsed = try g.imports(std.testing.allocator, language, source);
    defer parsed.deinit();
    const specs = parsed.items();
    try std.testing.expectEqual(want.len, specs.len);
    for (specs, want) |spec, name| try eq(name, spec.name);
}
test "Zig comments strings characters multiline strings and whitespace" {
    try check(.zig,
        \\// @import("fake.zig")
        \\const text = "@import(\"fake.zig\")";
        \\const character = '"';
        \\const multi =
        \\    \\@import("fake.zig")
        \\;
        \\const real = @import /* invalid Zig comment: no such syntax */ ("bad.zig");
        \\const a = @import (
        \\    "a.zig"
        \\);
        \\const b = @import("b\x2ezig");
    , &.{ "a.zig", "b.zig" });
}
test "Zig member references direct bound typed and multiline with no comments or strings" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var parsed = try g.imports(std.testing.allocator, .zig,
        \\const p: type = @import("proto");
        \\const m = p
        \\    .mirror;
        \\const x = @import("proto").mirror;
        \\// p.mirror
        \\const s = "p.mirror";
        \\const y = other.p.mirror;
    );
    defer parsed.deinit();
    const specs = parsed.items();
    var members: usize = 0;
    for (specs) |s| if (s.member) |m| {
        try eq("mirror", m);
        members += 1;
    };
    try std.testing.expectEqual(2, members);
}
test "C include directives angle headers comments strings raw strings" {
    try check(.c,
        \\/* #include "bad.h" */
        \\const char *s = "#include \"bad.h\"";
        \\auto raw = R"end(
        \\#include "bad.h"
        \\)end";
        \\// #include "bad.h"
        \\ # include "local.h"
        \\#include <lib/other.h>
        \\#include MACRO
        \\a #include "bad.h"
    , &.{ "local.h", "lib/other.h" });
}
test "JS and TS imports reexports require dynamic import and comments" {
    try check(.javascript,
        \\// import 'bad';
        \\/* require('bad') */
        \\const s = "import 'bad'";
        \\const t = `require('bad')`;
        \\const r = /import['"]bad['"]/;
        \\import './side';
        \\import type { Thing } from "./types";
        \\export { x } from './x';
        \\export * from './all';
        \\const a = require (
        \\ './cjs'
        \\);
        \\const b = import('./dyn', { with: { type: 'json' } });
        \\import(variable);
        \\object.require('./bad');
        \\const c = require('./es\x63');
    , &.{ "./side", "./types", "./x", "./all", "./cjs", "./dyn", "./esc" });
}
test "Python absolute relative aliased and parenthesized imports ignore docstrings" {
    try check(.python,
        \\# import bad
        \\s = "import bad"
        \\doc = '''
        \\from bad import broken
        \\'''
        \\import a.b as ab, c
        \\from . import helper
        \\from ..pkg import (
        \\    x as other,
        \\    y,
        \\)
        \\from root import *
    , &.{ "a.b", "c", ".", ".helper", "..pkg", "..pkg.x", "..pkg.y", "root" });
}
test "Python semicolons conditional imports escaped and raw triple docstrings" {
    try check(.python,
        \\r''' import fake '''
        \\if True: import a; import b as other
        \\from pkg import a, \
        \\ b
    , &.{ "a", "b", "pkg", "pkg.a", "pkg.b" });
}
test "Nim imports groups prefixes strings and pragmas ignore comments strings and characters" {
    try check(.nim,
        \\# import bad
        \\#[ import bad
        \\   #[ nested ]# import bad
        \\]#
        \\##[ import bad ]##
        \\let s = "import bad"
        \\let r = r"C:\import\" & "x"
        \\let t = """
        \\import bad"""
        \\let q = '"'
        \\let n = 1'i8
        \\import std/[os,
        \\  strutils], ../lib/a as b, c {.all.}
        \\import std / times
        \\from pkg/d {.all.} as dd import nil
        \\import n.o as p, .. / q / [r as s, t]
        \\import "."/[l,
        \\  m,
        \\]
        \\include "e/f", ./g
        \\import h except i, j
        \\when defined(x): import k
        \\proc p() {.importc: "import".}
        \\obj.import
    , &.{ "std/os", "std/strutils", "../lib/a", "c", "std/times", "pkg/d", "n/o", "../q/r", "../q/t", "./l", "./m", "e/f", "./g", "h", "k" });
}
test "Java package and imports ignore comments strings text blocks characters and members" {
    var parsed = try g.imports(std.testing.allocator, .java,
        \\// import bad.One;
        \\/* import bad.Two; */
        \\package com.acme
        \\  .app;
        \\import java.util.List;
        \\import static java.util.Map.entry;
        \\import com.acme.model.*;
        \\import static com.acme.Util.*;
        \\class A {
        \\  String s = "import bad.Three;";
        \\  String t = """
        \\    import bad.Four;
        \\    \"""; import bad.Five;
        \\    """;
        \\  char q = '"';
        \\  void m() { obj.import(); }
        \\}
        \\import after.Body;
    );
    defer parsed.deinit();
    const specs = parsed.items();
    try std.testing.expectEqual(5, specs.len);
    for (specs, [_][]const u8{ "java.util.List", "java.util.Map.entry", "com.acme.model.*", "com.acme.Util.*", "after.Body" }) |spec, name| try eq(name, spec.name);
    try expect(specs[1].form == .java_static and !specs[1].star);
    try expect(specs[2].form == .literal and specs[2].star);
    try expect(specs[3].form == .java_static and specs[3].star);
}
test "Groovy and Kotlin interpolation keeps nested braces and strings inside one template" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const lexer = @import("lexer.zig");
    const groovy = try lexer.lex(.groovy, arena.allocator(), "x \"${ f { a } + \"y\" }\" 'z' \"$w\" \"plain\"");
    try std.testing.expectEqual(5, groovy.len);
    try expect(groovy[1].kind == .template and groovy[3].kind == .template);
    try expect(groovy[2].kind == .string and groovy[4].kind == .string);
    const kotlin = try lexer.lex(.kotlin, arena.allocator(), "/* a /* b */ c */ `if` 'q' \"${'$'}{v}\" \"\"\"raw $x\"\"\" \"plain\"");
    try std.testing.expectEqual(3, kotlin.len);
    try expect(kotlin[0].kind == .word and kotlin[1].kind == .template and kotlin[2].kind == .string);
}
test "Go aliased dot blank block raw imports ignore comments and raw text" {
    try check(.go,
        \\package main
        \\// import "bad"
        \\/* import "bad" */
        \\var text = `import "bad"`
        \\import alias "example.com/x/a"
        \\import (
        \\ . "example.com/x/b"
        \\ _ `example.com/x/c`
        \\ "fmt"
        \\)
    , &.{ "example.com/x/a", "example.com/x/b", "example.com/x/c", "fmt" });
}
test "Rust mod use trees nested comments raw strings and lifetimes" {
    try check(.rust,
        \\/* mod bad; /* use crate::bad; */ */
        \\let s = r###"mod bad; use crate::bad;"###;
        \\let c = 'x';
        \\fn f<'a>(x: &'a str) {}
        \\pub(crate) mod net;
        \\use crate::util::Thing;
        \\use super::shared;
        \\use self::local;
        \\use crate::{alpha, beta::{one, two}, gamma};
        \\mod inline { }
        \\use external::Thing;
    , &.{ "net", "crate::util::Thing", "super::shared", "self::local", "crate::alpha", "crate::beta::one", "crate::beta::two", "crate::gamma" });
}
test "unterminated strings and comments do not invent imports" {
    for ([_]g.Language{ .zig, .c, .javascript, .python, .go, .rust }) |language| {
        try check(language, "\" unterminated @import(\"bad\")", &.{});
    }
    try check(.rust, "/* mod bad;", &.{});
}
test "ordinary escapes decode unicode and reject malformed paths" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const decode = @import("lexer.zig").decode;
    try eq("xé", try decode(arena.allocator(), "x\\u00e9"));
    try std.testing.expectError(error.InvalidEscape, decode(arena.allocator(), "\\uD800"));
    try std.testing.expectError(error.InvalidEscape, decode(arena.allocator(), "\\x"));
}

test "JS regex after control flow and nested template expressions" {
    try check(.javascript,
        \\if (ok) /require('bad')/.test(s);
        \\while (ok) /import('bad')/.test(s);
        \\const t = `import('bad') ${import('./yes')} ${`raw ${require('./nested')}`}`;
    , &.{ "./yes", "./nested" });
}

test "prefixed C++ and Rust byte raw strings keep embedded syntax inert" {
    try check(.c,
        \\auto s = u8R"tag("quote"
        \\#include "fake.h"
        \\)tag";
        \\auto w = LR"("more"
        \\#include "fake.h"
        \\)";
        \\#include "real.h"
    , &.{"real.h"});
    try check(.rust,
        \\let s = br##""quoted" mod fake; use crate::fake;"##;
        \\mod real;
    , &.{"real"});
}
test "C directives survive continued lines and multiline comments" {
    try check(.c,
        \\int a; /* comment
        \\*/ # include \
        \\ "real.h"
    , &.{"real.h"});
}
test "owned raw imports outlive the source and clean up on allocation failure" {
    const source = try std.testing.allocator.dupe(u8, "const p = @import(\"proto\"); const m = p.mirror;");
    var parsed = try g.imports(std.testing.allocator, .zig, source);
    defer parsed.deinit();
    std.testing.allocator.free(source);
    try eq("proto", parsed.items()[0].name);
    const S = struct {
        fn run(a: std.mem.Allocator) !void {
            var result = try g.imports(a, .zig, "const p = @import(\"proto\"); const m = p.mirror;");
            defer result.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, S.run, .{});
}

test "JS escapes retain Unicode characters and identity escapes in specifiers" {
    try check(.javascript,
        \\import './\xE9';
        \\import './\u{1f600}';
        \\import './\uD83D\uDE00';
        \\require('./\q');
    , &.{ "./é", "./😀", "./😀", "./q" });
}
