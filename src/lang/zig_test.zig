const std = @import("std");
const g = @import("../gantry.zig");
const a = std.testing.allocator;
const support = @import("../testing/support.zig");

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

test "Zig field names, labels and member access are not references; an enum literal may be" {
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
        \\fn List(comptime T: type) type { return struct { items: []T }; }
        \\fn a() error{Bad}!void { _ = @import("a.zig"); }
        \\fn b() List(u8) { _ = @import("b.zig"); return .{ .items = &.{} }; }
        \\fn c() union(enum) { x: u8 } { _ = @import("c.zig"); return .{ .x = 0 }; }
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

test "Zig members are read through every alias, public ones and ones after a range" {
    var imports = try g.imports(a, .zig,
        \\const std = @import("std");
        \\pub const util = @import("util.zig");
        \\pub fn run(b: []const u8) []const u8 { return b[0..std.mem.len(b)]; }
        \\pub const Temp = util.Temp;
        \\pub fn spaced(b: []const u8) []const u8 { return b[0 .. std.mem.len(b)]; }
    );
    defer imports.deinit();
    var members: usize = 0;
    for (imports.items()) |spec| members += @intFromBool(spec.member != null);
    try std.testing.expectEqual(3, members);
}

test "Zig source without tests is all import" {
    try expectKinds(
        \\const x = @import("x.zig");
        \\pub fn f() void { _ = @import("y.zig"); }
    , &.{ .{ "x.zig", .import }, .{ "y.zig", .import } });
    try expectKinds("test { const x = @import(\"x.zig\"); _ = x; }", &.{.{ "x.zig", .@"test" }});
}

test "Zig source std rejects has no facts" {
    for ([_][]const u8{
        "} ) ] const x = @import(\"x.zig\"); fn ( { @import(\"y.zig\")",
        "test { const x = @import(\"x.zig\"); } } } test",
        "pub const T = if (true) struct { const x = @import(\"x.zig\");",
        // Syntax std accepts but lowering rejects: an unused local.
        "pub fn f() void { const unused = 1; }",
        "pub const x = @import(\"\\q\");",
        // Bytes that are not UTF-8: std's lowering would read past a cut character literal.
        "pub const c = '\xf0';",
        "// caf\xe9\npub const x = 1;",
    }) |source| try std.testing.expectError(error.InvalidSource, g.imports(a, .zig, source));
    var deep: std.ArrayList(u8) = .empty;
    defer deep.deinit(a);
    try deep.appendSlice(a, "pub const v = ");
    for (0..300) |_| try deep.append(a, '(');
    try deep.append(a, '1');
    for (0..300) |_| try deep.append(a, ')');
    try deep.append(a, ';');
    try std.testing.expectError(error.InvalidSource, g.imports(a, .zig, deep.items));
}

test "Zig computed imports are refused, not guessed" {
    for ([_][]const u8{
        "const name = \"x.zig\"; pub const a = @import(name);",
        "pub const b = @import(\"b\" ++ \".zig\");",
    }) |source| try std.testing.expectError(error.InvalidSource, g.imports(a, .zig, source));
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

test "Zig calls resolve to the member their receiver has, not to one that shares the name" {
    // Only tests call the file's `apply`; `s.apply()` is the method.
    try expectKinds(
        \\const config = @import("config.zig");
        \\const Session = struct {
        \\    fn apply(s: *const Session) void { _ = s; }
        \\    pub fn run(s: *const Session) void { s.apply(); }
        \\};
        \\fn apply(c: *const config.Config) void { _ = c; }
        \\pub fn start() void { const s: Session = .{}; s.run(); }
        \\test { apply(undefined); }
    , &.{.{ "config.zig", .@"test" }});
}

test "Zig calls on a receiver glint cannot resolve may call any member of that name" {
    try expectKinds(
        \\const util = @import("util.zig");
        \\fn flush() void { util.go(); }
        \\pub fn run(writer: anytype) void { writer.flush(); }
        \\test { flush(); }
    , &.{.{ "util.zig", .import }});
}

/// The `@import` names of `source` that no build analyses, in source order.
fn expectDead(source: []const u8, expected: []const []const u8) !void {
    var imports = try g.imports(a, .zig, source);
    defer imports.deinit();
    var n: usize = 0;
    for (imports.items()) |spec| if (spec.member == null and spec.dead) {
        if (n >= expected.len) {
            std.debug.print("dead: {s}\n{s}\n", .{ spec.name, source });
            return error.TestUnexpectedImport;
        }
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

test "Zig liveness keeps colliding names distinct as a file grows" {
    for ([_]usize{ 3, 8, 12, 16, 30, 300, 3000 }) |n| {
        var source: std.ArrayList(u8) = .empty;
        defer source.deinit(a);
        // These names have the same length and first and last byte.
        for (0..n) |i| try source.print(a, "const a{d:0>4}z = @import(\"{d}.zig\");\n", .{ i, i });
        try source.appendSlice(a, "pub fn f() void { _ = a0000z; }\ntest { _ = a0001z; }\n");
        var imports = try g.imports(a, .zig, source.items);
        defer imports.deinit();
        try std.testing.expectEqual(n, imports.items().len);
        for (imports.items(), 0..) |spec, i| {
            try std.testing.expectEqual(i >= 2, spec.dead);
            try std.testing.expectEqual(if (i == 1) g.Kind.@"test" else g.Kind.import, spec.kind);
        }
    }
}

test "Zig recovery releases everything it took when an allocation fails" {
    const S = struct {
        fn run(allocator: std.mem.Allocator, text: []const u8) !void {
            var imports = try g.imports(allocator, .zig, text);
            defer imports.deinit();
            // builtin, fixture, prod and late, and the member of builtin.
            try std.testing.expectEqual(@as(usize, 5), imports.items().len);
            for (imports.items()) |spec| {
                const want: g.Kind = if (std.mem.eql(u8, spec.name, "fixture.zig") or std.mem.eql(u8, spec.name, "late.zig")) .@"test" else .import;
                try std.testing.expectEqual(want, spec.kind);
            }
        }
    };
    try support.checkAllAllocationFailures(S.run, .{
        \\const builtin = @import("builtin");
        \\pub const value = if (builtin.is_test) @import("fixture.zig") else @import("prod.zig");
        \\test { _ = @import("late.zig"); }
    });
}

test "Zig structural lists past their first allocation keep every builtin alias and test mark" {
    var source: std.Io.Writer.Allocating = .init(a);
    defer source.deinit();
    for (0..6) |i| try source.writer.print("pub const b{d} = @import(\"builtin\");\n", .{i});
    for (0..128) |_| try source.writer.writeAll("test { if (b5.is_test) { _ = @import(\"x.zig\"); } }\n");
    var expected: [134]struct { []const u8, g.Kind } = undefined;
    for (expected[0..6]) |*entry| entry.* = .{ "builtin", .import };
    for (expected[6..]) |*entry| entry.* = .{ "x.zig", .@"test" };
    try expectKinds(source.written(), &expected);
}

/// Forty Zig files scanned on `io`: each says what it says alone, in path order.
fn scanMany(io: std.Io) !void {
    var items: std.ArrayList(support.Item) = .empty;
    defer {
        for (items.items) |item| {
            a.free(item.path);
            a.free(item.text.?);
        }
        items.deinit(a);
    }
    for (0..40) |i| {
        try items.append(a, .{
            .path = try a.print("z{d:0>2}.zig", .{i}),
            .text = try a.print("const next = @import(\"z{d:0>2}.zig\");\nconst unused = @import(\"u.zig\");\npub fn f() void {{ _ = next; }}\ntest {{ _ = @import(\"t.zig\"); }}\n", .{(i + 1) % 40}),
        });
    }
    const paths = try a.alloc([]const u8, items.items.len);
    defer a.free(paths);
    for (items.items, paths) |item, *path| path.* = item.path;
    const fixture: support.Fixture = .{ .items = items.items };
    var graph = try g.scan(a, io, paths, fixture, support.Fixture.read, .{});
    defer graph.deinit();
    try std.testing.expectEqual(40, graph.edges().len);
    for (graph.edges()) |edge| try std.testing.expectEqual(g.Kind.import, edge.kind);
    var dead: usize = 0;
    var tests: usize = 0;
    for (graph.references()) |reference| {
        dead += @intFromBool(reference.dead);
        tests += @intFromBool(reference.kind == .@"test");
    }
    try std.testing.expectEqual(40, dead);
    try std.testing.expectEqual(40, tests);
    try std.testing.expectEqual(0, graph.invalid().len);
}

test "a scan of many Zig files recovers them on the tasks its io runs" {
    try scanMany(std.testing.io);
}

test "a scan of many Zig files gives the same graph when its io runs no task at once" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    try scanMany(threaded.io());
}

test "a scan records a Zig file std rejects and goes on" {
    const items = [_]support.Item{
        .{ .path = "ok.zig", .text = "pub const a = @import(\"b.zig\");" },
        .{ .path = "b.zig", .text = "pub const x = 1;" },
        .{ .path = "broken.zig", .text = "pub const a = @import(\"b.zig\")" },
    };
    var graph = try (support.Fixture{ .items = &items }).scan(a, .{});
    defer graph.deinit();
    try support.edge(&graph, "ok.zig", "b.zig", .import, 1);
    try support.invalid(&graph, "broken.zig", error.InvalidSource);
    try std.testing.expectEqual(.imports, graph.invalid()[0].phase);
}
