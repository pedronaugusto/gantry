const std = @import("std");
const g = @import("../gantry.zig");
const f = @import("../testing/support.zig");
const a = std.testing.allocator;
const eq = std.testing.expectEqual;

test "fixture: a Maven Java project resolves types, packages, statics, tests and its declarations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const items = [_]f.Item{
        .{ .path = "src/main/java/com/acme/app/App.java", .text =
        \\package com.acme.app;
        \\
        \\import com.acme.util.Strings;
        \\import com.acme.model.*;
        \\import static com.acme.util.Strings.join;
        \\import java.util.List;
        \\
        \\public class App {}
        },
        .{ .path = "src/main/java/com/acme/util/Strings.java", .text = "package com.acme.util;\npublic final class Strings { public static class Inner {} }" },
        .{ .path = "src/main/java/com/acme/model/User.java", .text = "package com.acme.model;\npublic record User(String name) {}" },
        .{ .path = "src/main/java/com/acme/model/Order.java", .text = "package com.acme.model;\nimport com.acme.util.Strings.Inner;\npublic class Order {}" },
        .{ .path = "src/main/java/com/acme/model/package-info.java", .text = "@Deprecated\npackage com.acme.model;" },
        .{ .path = "src/test/java/com/acme/app/AppTest.java", .text = "package com.acme.app;\nimport com.acme.util.Strings.Inner;\nimport org.junit.Test;\nclass AppTest {}" },
        .{ .path = "pom.xml", .text = "<project><dependencies><dependency><groupId>junit</groupId><artifactId>junit</artifactId><version>4.13.2</version><scope>test</scope></dependency></dependencies></project>" },
    };
    var paths: [items.len][]const u8 = undefined;
    for (items, &paths) |item, *path| {
        path.* = item.path;
        if (g.path.dir(item.path).len > 0) try tmp.dir.createDirPath(io, g.path.dir(item.path));
        try tmp.dir.writeFile(io, .{ .sub_path = item.path, .data = item.text.? });
    }
    var graph = try g.scan(a, &paths, g.DirReader{ .io = io, .dir = tmp.dir }, g.DirReader.read, .{});
    defer graph.deinit();
    const app = "src/main/java/com/acme/app/App.java";
    const strings = "src/main/java/com/acme/util/Strings.java";
    try f.edge(&graph, app, strings, .import, 2);
    try f.edge(&graph, app, "src/main/java/com/acme/model/User.java", .import, 1);
    try f.edge(&graph, app, "src/main/java/com/acme/model/Order.java", .import, 1);
    try f.edge(&graph, "src/main/java/com/acme/model/Order.java", strings, .import, 1);
    try f.edge(&graph, "src/test/java/com/acme/app/AppTest.java", strings, .@"test", 1);
    try eq(5, graph.edges().len);
    var unresolved: usize = 0;
    for (graph.references()) |ref| if (!ref.resolved) {
        unresolved += 1;
    };
    try eq(2, unresolved);
    try eq(1, graph.dependencies().len);
    try std.testing.expectEqualStrings("junit:junit", graph.dependencies()[0].name);
    try eq(g.Dependency.Scope.development, graph.dependencies()[0].scope());
}

test "Java types resolve by declared package wherever the file sits" {
    var graph = try (f.Fixture{ .items = &.{
        .{ .path = "a/Main.java", .text = "package app; import lib.Util; import lib.Util.Nested.Deeper; import static lib.Util.*; import lib.Util.*; import other.Thing; import lib.Missing;" },
        .{ .path = "elsewhere/Util.java", .text = "package lib; class Util {}" },
        .{ .path = "lib/Helper.java", .text = "package lib; class Helper {}" },
        .{ .path = "one/other/Thing.java", .text = "package other; class Thing {}" },
        .{ .path = "two/other/Thing.java", .text = "package other; class Thing {}" },
        .{ .path = "Default.java", .text = "class Default {}" },
        .{ .path = "b/Use.java", .text = "package b; import Default; import lib.*;" },
    } }).scan(a, .{});
    defer graph.deinit();
    // single, nested and static imports fall back to the enclosing type's file
    try f.edge(&graph, "a/Main.java", "elsewhere/Util.java", .import, 4);
    // a type two roots declare resolves to both
    try f.edge(&graph, "a/Main.java", "one/other/Thing.java", .import, 1);
    try f.edge(&graph, "a/Main.java", "two/other/Thing.java", .import, 1);
    // `lib.*` is the package, never the unnamed package's types
    try f.edge(&graph, "b/Use.java", "elsewhere/Util.java", .import, 1);
    try f.edge(&graph, "b/Use.java", "lib/Helper.java", .import, 1);
    try eq(5, graph.edges().len);
}

test "Java on-demand imports of a type name its file, not a package" {
    var graph = try (f.Fixture{ .items = &.{
        .{ .path = "Main.java", .text = "package app; import lib.Outer.*; import static lib.Outer.*;" },
        .{ .path = "lib/Outer.java", .text = "package lib; class Outer {}" },
        .{ .path = "lib/Outer/Ghost.java", .text = "package lib.Outer; class Ghost {}" },
    } }).scan(a, .{});
    defer graph.deinit();
    // the package exists, so the plain import names it; the static one names the type
    try f.edge(&graph, "Main.java", "lib/Outer/Ghost.java", .import, 1);
    try f.edge(&graph, "Main.java", "lib/Outer.java", .import, 1);
    try eq(2, graph.edges().len);
}

test "Java test sources follow Maven and Gradle source sets" {
    var graph = try (f.Fixture{ .items = &.{
        .{ .path = "src/main/java/p/A.java", .text = "package p; class A {}" },
        .{ .path = "src/test/java/p/ATest.java", .text = "package p; import p.A;" },
        .{ .path = "src/testFixtures/java/p/Fix.java", .text = "package p; import p.A;" },
        .{ .path = "src/integrationTest/java/p/AIT.java", .text = "package p; import p.A;" },
        .{ .path = "src/main/java/p/test/Tool.java", .text = "package p.test; import p.A;" },
    } }).scan(a, .{});
    defer graph.deinit();
    try f.edge(&graph, "src/test/java/p/ATest.java", "src/main/java/p/A.java", .@"test", 1);
    try f.edge(&graph, "src/testFixtures/java/p/Fix.java", "src/main/java/p/A.java", .@"test", 1);
    try f.edge(&graph, "src/integrationTest/java/p/AIT.java", "src/main/java/p/A.java", .@"test", 1);
    try f.edge(&graph, "src/main/java/p/test/Tool.java", "src/main/java/p/A.java", .import, 1);
}

test "Java sources are read once for packages and imports" {
    const Reader = struct {
        const Self = @This();
        calls: usize = 0,
        fn read(scratch: std.mem.Allocator, self: *Self, name: []const u8) !?[]const u8 {
            self.calls += 1;
            const value = try scratch.dupe(u8, if (std.mem.eql(u8, name, "A.java")) "package a; import b.B;" else "package b; class B {}");
            return value;
        }
    };
    var reader: Reader = .{};
    var graph = try g.scan(a, &.{ "A.java", "B.java" }, &reader, Reader.read, .{});
    defer graph.deinit();
    try f.edge(&graph, "A.java", "B.java", .import, 1);
    try eq(2, reader.calls);
}
