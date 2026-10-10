const std = @import("std");
const g = @import("../gantry.zig");
const a = std.testing.allocator;
const support = @import("../testing/support.zig");

/// The kind of each `@import` of `source`, by name, in source order.
fn expectKinds(source: []const u8, expected: []const struct { []const u8, g.Kind }) !void {
    var imports = try support.imports(a, .zig, source);
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

test "Zig field names, labels and member access are not references; an enum literal is" {
    try expectKinds(
        \\const mem = @import("mem.zig");
        \\const len = @import("len.zig");
        \\const blk = @import("blk.zig");
        \\const tag = @import("tag.zig");
        \\pub const S = struct { len: usize, fn f(s: S) usize { return blk: { _ = .tag; break :blk s.len; }; } };
        \\pub fn g(x: anytype) void { _ = x.mem; }
        \\test { _ = mem; _ = len; _ = blk; _ = tag; }
    , &.{ .{ "mem.zig", .@"test" }, .{ "len.zig", .@"test" }, .{ "blk.zig", .@"test" }, .{ "tag.zig", .import } });
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
    var imports = try support.imports(a, .zig,
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

test "Zig is_test is a test condition only on an alias of builtin or the literal form" {
    try expectKinds(
        \\const options = @import("options");
        \\const b = @import("builtin");
        \\pub fn run(opts: anytype) void {
        \\    if (options.is_test) { _ = @import("a.zig"); }
        \\    if (opts.is_test) _ = @import("b.zig");
        \\    if (b.is_test) _ = @import("c.zig");
        \\}
    , &.{ .{ "options", .import }, .{ "builtin", .import }, .{ "a.zig", .import }, .{ "b.zig", .import }, .{ "c.zig", .@"test" } });
}

test "Zig decl literals and @field of the container are references" {
    try expectKinds(
        \\const Pool = @This();
        \\const defaults = @import("testing/defaults.zig");
        \\const empties = @import("empties.zig");
        \\const fielded = @import("fielded.zig");
        \\const selfed = @import("selfed.zig");
        \\items: u8,
        \\const default: Pool = .{ .items = defaults.empty };
        \\const empty: Pool = .{ .items = empties.empty };
        \\const by_field = fielded.x;
        \\const by_self = selfed.x;
        \\pub fn init() Pool { return .default; }
        \\pub fn reset(p: *Pool) void { p.* = .empty; _ = @field(@This(), "by_field"); _ = @field(Pool, "by_self"); }
        \\test { _ = default; _ = empty; _ = by_field; _ = by_self; }
    , &.{ .{ "testing/defaults.zig", .import }, .{ "empties.zig", .import }, .{ "fielded.zig", .import }, .{ "selfed.zig", .import } });
}

test "Zig field initialisers and member access are not decl literals" {
    try expectKinds(
        \\const items = @import("items.zig");
        \\const len = @import("len.zig");
        \\pub const S = struct { items: u8, len: u8 };
        \\pub fn f(s: S) S { _ = s.len; return .{ .items = 1, .len = 2 }; }
        \\test { _ = items; _ = len; }
    , &.{ .{ "items.zig", .@"test" }, .{ "len.zig", .@"test" } });
}

/// The `@import` names of `source` that no build analyses, in source order.
fn expectDead(source: []const u8, expected: []const []const u8) !void {
    var imports = try support.imports(a, .zig, source);
    defer imports.deinit();
    var n: usize = 0;
    for (imports.items()) |spec| if (spec.member == null and spec.dead) {
        if (n >= expected.len) return error.TestUnexpectedImport;
        try std.testing.expectEqualStrings(expected[n], spec.name);
        n += 1;
    };
    try std.testing.expectEqual(expected.len, n);
}

test "Zig imports in declarations nothing reaches are dead, tests or none" {
    try expectDead("const a = @import(\"a.zig\");\npub fn f() void {}\n", &.{"a.zig"});
    try expectDead("const std = @import(\"std\");\npub fn f() void {}\n", &.{"std"});
    // A chain from a dead declaration stays dead.
    try expectDead("const a = @import(\"a.zig\");\nfn helper() void { _ = a; }\npub fn f() void {}\n", &.{"a.zig"});
    try expectDead("const a = @import(\"a.zig\");\nconst S = struct { const b = @import(\"b.zig\"); };\n", &.{ "a.zig", "b.zig" });
    // A member of another value with the same name is not a use.
    try expectDead("const object = @import(\"object.zig\");\npub const U = union(enum) { none, object: struct { x: u8 }, };\n", &.{"object.zig"});
    try expectDead("const fs = @import(\"repo/fs.zig\");\nconst std = @import(\"std\");\npub const sep = std.fs.path.sep;\n", &.{"repo/fs.zig"});
    try expectDead("const a = @import(\"a.zig\");\npub fn f() void {}\ntest {}\n", &.{"a.zig"});
}

test "Zig imports a root, a test, a field, a call or a decl literal reaches are not dead" {
    for ([_][]const u8{
        "pub const a = @import(\"a.zig\");\n",
        "const a = @import(\"a.zig\");\npub fn f() void { _ = a; }\n",
        "const a = @import(\"a.zig\");\nfn helper() void { _ = a; }\npub fn f() void { helper(); }\n",
        "const a = @import(\"a.zig\");\ntest { _ = a; }\n",
        "const a = @import(\"a.zig\");\ntest a {}\n",
        "const a = @import(\"a.zig\");\ncomptime { _ = a; }\n",
        "const len = @import(\"a.zig\").len;\npub const B = [len:0]u8;\n",
        "const n = @import(\"a.zig\").n;\npub fn f(b: [:0]const u8) [:0]const u8 { return b[0..n :0]; }\n",
        "const a = @import(\"a.zig\");\nfield: a.T,\n",
        "const a = @import(\"a.zig\");\nexport fn f() void { _ = a; }\n",
        "const a = @import(\"a.zig\");\nfn main() void { _ = a; }\n",
        "const a = @import(\"a.zig\");\nfn helper(self: @This()) void { _ = self; _ = a; }\npub fn f(self: @This()) void { self.helper(); }\n",
        "const Self = @This();\nconst a = @import(\"a.zig\");\nconst helper = a.x;\npub const y = Self.helper;\n",
        "const a = @import(\"a.zig\");\nconst helper = a.x;\npub const y = @This().helper;\n",
        "const builtin = @import(\"builtin\");\nconst a = @import(\"a.zig\");\npub fn f() void { if (builtin.is_test) _ = a; }\n",
        "const Self = @This();\nconst a = @import(\"a.zig\");\nx: u32,\nconst default: Self = .{ .x = a.v };\npub fn init() Self { return .default; }\n",
        "const a = @import(\"a.zig\");\nconst helper = a.x;\npub fn f() void { _ = @field(@This(), \"helper\"); }\n",
    }) |text| try expectDead(text, &.{});
}

test "Zig small-file liveness fits in an 8 KiB heap allocation budget" {
    const shakedown = @import("shakedown");
    var counted: shakedown.alloc.Counting = .init(a);
    var imports = try support.imports(counted.allocator(), .zig,
        \\const dep = @import("dep.zig");
        \\pub fn f() void { _ = dep; }
    );
    defer imports.deinit();
    try std.testing.expectEqual(@as(usize, 1), imports.items().len);
    try std.testing.expect(!imports.items()[0].dead);
    try std.testing.expectEqual(g.Kind.import, imports.items()[0].kind);
    std.testing.expect(counted.total_bytes <= 8 * 1024) catch |err| {
        std.debug.print("small-file heap: total {d}, peak {d}, allocations {d}\n", .{ counted.total_bytes, counted.peak_bytes, counted.allocations });
        return err;
    };
}

test "Zig liveness keeps colliding names distinct as a file grows" {
    for ([_]usize{ 3, 8, 12, 16, 30, 300, 3000 }) |n| {
        var source: std.ArrayList(u8) = .empty;
        defer source.deinit(a);
        // These names have the same length and first and last byte. Some
        // share every sampled byte too, so collision chains remain needed.
        for (0..n) |i| try source.print(a, "const a{d:0>4}z = @import(\"{d}.zig\");\n", .{ i, i });
        try source.appendSlice(a, "pub fn f() void { _ = a0000z; }\ntest { _ = a0001z; }\n");
        var imports = try support.imports(a, .zig, source.items);
        defer imports.deinit();
        try std.testing.expectEqual(n, imports.items().len);
        for (imports.items(), 0..) |spec, i| {
            try std.testing.expectEqual(i >= 2, spec.dead);
            try std.testing.expectEqual(if (i == 1) g.Kind.@"test" else g.Kind.import, spec.kind);
        }
    }
}

test "Zig streamed recovery keeps deep nesting and truncated test branches classified" {
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(a);
    try source.appendSlice(a, "const builtin = @import(\"builtin\"); pub const value = ");
    for (0..768) |_| try source.append(a, '(');
    try source.appendSlice(a, "if (builtin.is_test) @import(\"fixture.zig\") else @import(\"prod.zig\")");
    for (0..768) |_| try source.append(a, ')');
    try source.appendSlice(a, "; test { _ = @import(\"late.zig\"); }");
    try expectKinds(source.items, &.{ .{ "builtin", .import }, .{ "fixture.zig", .@"test" }, .{ "prod.zig", .import }, .{ "late.zig", .@"test" } });
    // The unfinished expression still ends at the stream's final token.
    try expectKinds("const b = @import(\"builtin\"); pub const T = if (b.is_test) struct { const x = @import(\"x.zig\");", &.{ .{ "builtin", .import }, .{ "x.zig", .@"test" } });
    const S = struct {
        fn run(allocator: std.mem.Allocator, text: []const u8) !void {
            var imports = try support.imports(allocator, .zig, text);
            defer imports.deinit();
            try std.testing.expectEqual(@as(usize, 5), imports.items().len);
            try std.testing.expectEqual(g.Kind.@"test", imports.items()[1].kind);
            try std.testing.expectEqual(g.Kind.import, imports.items()[2].kind);
        }
    };
    try support.checkAllAllocationFailures(S.run, .{source.items});
}

test "Zig streamed structural spills retain every builtin alias and test mark" {
    var source: std.Io.Writer.Allocating = .init(a);
    defer source.deinit();
    for (0..6) |i| try source.writer.print("pub const b{d} = @import(\"builtin\"); ", .{i});
    for (0..128) |_| try source.writer.writeAll("test { if (b5.is_test) { _ = @import(\"x.zig\"); } } ");
    var expected: [134]struct { []const u8, g.Kind } = undefined;
    for (expected[0..6]) |*entry| entry.* = .{ "builtin", .import };
    for (expected[6..]) |*entry| entry.* = .{ "x.zig", .@"test" };
    try expectKinds(source.written(), &expected);
    source.clearRetainingCapacity();
    for (0..12) |i| try source.writer.print("pub const x{d} = @import(\"x.zig\"); ", .{i});
    const short_expected: [12]struct { []const u8, g.Kind } = @splat(.{ "x.zig", .import });
    try std.testing.expect(source.written().len <= 1024);
    try expectKinds(source.written(), &short_expected);
}

test "Zig files without their frontend fail the scan before anything is read" {
    const Reader = struct {
        const Self = @This();
        reads: usize = 0,
        fn read(self: *Self, _: std.mem.Allocator, _: std.Io, _: []const u8) !?[]const u8 {
            self.reads += 1;
            return "const x = @import(\"x.zig\");";
        }
    };
    var reader: Reader = .{};
    var diagnostic = g.Diagnostics.init(a);
    defer diagnostic.deinit();
    const paths = &.{ "a.py", "src/a.zig" };
    try std.testing.expectError(error.FrontendMissing, g.scan(a, std.testing.io, paths, &reader, Reader.read, .{ .diagnostics = &diagnostic }));
    try std.testing.expectEqual(0, reader.reads);
    try std.testing.expectEqualStrings("src/a.zig", diagnostic.failure.?.path.?);
    try std.testing.expectEqual(error.FrontendMissing, diagnostic.failure.?.cause);
    // Token rules read Zig too, whatever edges are wanted.
    try std.testing.expectError(error.FrontendMissing, g.scan(a, std.testing.io, paths, &reader, Reader.read, .{ .kinds = &.{.link}, .tokens = &.{.{ .name = "any", .tokens = &.{"*"} }} }));
    // A scan that reads no code needs no frontend for the Zig files it lists.
    var links = try g.scan(a, std.testing.io, paths, &reader, Reader.read, .{ .kinds = &.{.link} });
    defer links.deinit();
    try std.testing.expectEqual(0, links.invalid().len);
    var listed = try support.scan(a, std.testing.io, paths, &reader, Reader.read, .{});
    defer listed.deinit();
}

test "Zig single-file recovery needs its frontend and reports it" {
    try std.testing.expectError(error.FrontendMissing, g.imports(a, .zig, "const x = @import(\"x.zig\");"));
    var imports = try g.importsWith(a, support.zig.frontend, "const x = @import(\"x.zig\");");
    defer imports.deinit();
    try std.testing.expectEqual(1, imports.items().len);
    try std.testing.expectEqualStrings("x.zig", imports.items()[0].name);
}
