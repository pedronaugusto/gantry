const std = @import("std");
const g = @import("../gantry.zig");
const a = std.testing.allocator;

/// The kind of each `@import` of `source`, by name, in source order.
fn expectKinds(source: []const u8, expected: []const struct { []const u8, g.Kind }) !void {
    var imports = try g.imports(a, .zig, source);
    defer imports.deinit();
    var n: usize = 0;
    for (imports.items()) |spec| if (spec.member == null) {
        if (n >= expected.len) return error.TestUnexpectedImport;
        try std.testing.expectEqualStrings(expected[n][0], spec.name);
        std.testing.expectEqual(expected[n][1], spec.kind) catch |err| {
            std.debug.print("{s}\n", .{spec.name});
            return err;
        };
        n += 1;
    };
    try std.testing.expectEqual(expected.len, n);
}

test "Zig imports in unnamed, named, identifier and nested tests are test" {
    try expectKinds(
        \\pub const live = @import("live.zig");
        \\test { _ = @import("a.zig"); }
        \\test "named" { _ = @import("b.zig"); }
        \\test live { _ = @import("c.zig"); }
        \\pub const S = struct {
        \\    test { if (true) { _ = @import("d.zig"); } }
        \\};
    , &.{ .{ "live.zig", .import }, .{ "a.zig", .@"test" }, .{ "b.zig", .@"test" }, .{ "c.zig", .@"test" }, .{ "d.zig", .@"test" } });
}

test "Zig is_test branches are test, their else branches are not" {
    try expectKinds(
        \\const builtin = @import("builtin");
        \\pub fn run() void {
        \\    if (builtin.is_test) { _ = @import("a.zig"); } else { _ = @import("b.zig"); }
        \\    if (comptime builtin.is_test) _ = @import("c.zig");
        \\}
        \\pub const T = if (@import("builtin").is_test) struct { const x = @import("d.zig"); } else @import("e.zig");
    , &.{ .{ "builtin", .import }, .{ "a.zig", .@"test" }, .{ "b.zig", .import }, .{ "c.zig", .@"test" }, .{ "builtin", .import }, .{ "d.zig", .@"test" }, .{ "e.zig", .import } });
}

test "Zig aliases only tests use are test; a private function a pub function calls keeps its alias live" {
    try expectKinds(
        \\const fixture = @import("testing/fixture.zig");
        \\const util = @import("util.zig");
        \\fn helper() void { util.go(); }
        \\pub fn run() void { helper(); }
        \\test { fixture.check(); }
    , &.{ .{ "testing/fixture.zig", .@"test" }, .{ "util.zig", .import } });
}

test "Zig private functions only tests reach carry their imports into test" {
    try expectKinds(
        \\fn expectGood() void { _ = @import("expect.zig"); deeper(); }
        \\fn deeper() void { _ = @import("deeper.zig"); }
        \\pub fn run() void {}
        \\test { expectGood(); }
    , &.{ .{ "expect.zig", .@"test" }, .{ "deeper.zig", .@"test" } });
}

test "Zig method calls, Self members, fields and comptime blocks keep declarations live" {
    try expectKinds(
        \\const Self = @This();
        \\const io = @import("io.zig");
        \\const Kind = @import("kind.zig");
        \\const late = @import("late.zig");
        \\const table = @import("table.zig");
        \\kind: Kind,
        \\pub fn run(self: Self) void { self.flush(); _ = Self.rows; }
        \\fn flush(self: Self) void { _ = self; io.write(); }
        \\const rows = table.rows;
        \\comptime { _ = late; }
        \\test { _ = io; _ = Kind; _ = late; _ = table; }
    , &.{ .{ "io.zig", .import }, .{ "kind.zig", .import }, .{ "late.zig", .import }, .{ "table.zig", .import } });
}

test "Zig field names, labels, enum literals and member access are not references" {
    try expectKinds(
        \\const mem = @import("mem.zig");
        \\const len = @import("len.zig");
        \\const tag = @import("tag.zig");
        \\pub const S = struct { len: usize, fn f(s: S) usize { return blk: { _ = .tag; break :blk s.len; }; } };
        \\pub fn g(x: anytype) void { _ = x.mem; }
        \\test { _ = mem; _ = len; _ = tag; }
    , &.{ .{ "mem.zig", .@"test" }, .{ "len.zig", .@"test" }, .{ "tag.zig", .@"test" } });
}

test "Zig sentinels and range bounds are references" {
    try expectKinds(
        \\const n = @import("n.zig").n;
        \\const m = @import("m.zig").m;
        \\pub fn f(b: []u8) void { var x: [n:0]u8 = undefined; _ = &x; _ = b[0..m :0]; }
        \\test { _ = n; _ = m; }
    , &.{ .{ "n.zig", .import }, .{ "m.zig", .import } });
}

test "Zig recovers no import from a string and keeps unreached imports import" {
    try expectKinds(
        \\const text = "@import(\"fake.zig\")";
        \\const unused = @import("unused.zig");
        \\test { _ = text; }
    , &.{.{ "unused.zig", .import }});
}

test "Zig return types with braces and generic calls end a function at its body" {
    try expectKinds(
        \\fn a() error{Bad}!void { _ = @import("a.zig"); }
        \\fn b() List(u8) { _ = @import("b.zig"); }
        \\fn c() union(enum) { x: u8 } { _ = @import("c.zig"); }
        \\extern "c" fn d() void;
        \\fn e() void { _ = @import("e.zig"); }
        \\pub fn run() void { e(); }
        \\test { _ = a; _ = b; _ = c; _ = d; }
    , &.{ .{ "a.zig", .@"test" }, .{ "b.zig", .@"test" }, .{ "c.zig", .@"test" }, .{ "e.zig", .import } });
}

test "Zig member references through an alias take the kind of their use" {
    var imports = try g.imports(a, .zig,
        \\const util = @import("util.zig");
        \\pub fn run() void { util.live(); }
        \\test { util.check(); }
    );
    defer imports.deinit();
    var seen: usize = 0;
    for (imports.items()) |spec| if (spec.member) |member| {
        seen += 1;
        try std.testing.expectEqual(@as(g.Kind, if (std.mem.eql(u8, member, "check")) .@"test" else .import), spec.kind);
    };
    try std.testing.expectEqual(2, seen);
}

test "Zig source without tests is all import, whatever its shape" {
    try expectKinds(
        \\} ) ] const x = @import("x.zig"); fn ( { @import("y.zig")
    , &.{ .{ "x.zig", .import }, .{ "y.zig", .import } });
    try expectKinds("test { const x = @import(\"x.zig\"); } } } test", &.{.{ "x.zig", .@"test" }});
}
