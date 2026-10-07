const std = @import("std");
const g = @import("../gantry.zig");
const f = @import("support.zig");
const a = std.testing.allocator;

test "Python initializer policy distinguishes direct imports and modulefinder ancestors" {
    const fixture: f.Fixture = .{ .items = &.{
        .{ .path = "pkg/__init__.py" },                                                                                          .{ .path = "pkg/sub/__init__.py" },
        .{ .path = "pkg/sub/a.py", .text = "from . import child\nfrom pkg.sub import child\nfrom pkg.sub.child import Symbol" }, .{ .path = "pkg/sub/child.py" },
    } };
    var direct = try fixture.scan(a, .{ .python_initializers = .explicit });
    defer direct.deinit();
    try std.testing.expectEqual(1, direct.edges().len);
    try f.edge(&direct, "pkg/sub/a.py", "pkg/sub/child.py", .import, 3);
    var ancestors = try fixture.scan(a, .{ .python_initializers = .modulefinder });
    defer ancestors.deinit();
    try f.edge(&ancestors, "pkg/sub/a.py", "pkg/__init__.py", .import, 3);
    try f.edge(&ancestors, "pkg/sub/a.py", "pkg/sub/__init__.py", .import, 3);
}

test "Python star reexports follow literal all and named imports without inventing dynamic exports" {
    const fixture: f.Fixture = .{ .items = &.{
        .{ .path = "pkg/__init__.py", .text = "from .api import *\nfrom .dynamic import *" },
        .{ .path = "pkg/api.py", .text = "from .impl import Public as Exposed\nfrom .hidden import Private\n__all__ = ['Exposed']" },
        .{ .path = "pkg/impl.py" },
        .{ .path = "pkg/hidden.py" },
        .{ .path = "pkg/dynamic.py", .text = "from .hidden import Private\n__all__ = compute_exports()" },
    } };
    var graph = try fixture.scan(a, .{ .python_initializers = .explicit });
    defer graph.deinit();
    try f.edge(&graph, "pkg/__init__.py", "pkg/impl.py", .import, 1);
    try f.edge(&graph, "pkg/__init__.py", "pkg/api.py", .import, 1);
    try f.edge(&graph, "pkg/__init__.py", "pkg/dynamic.py", .import, 1);
    for (graph.edges()) |edge| try std.testing.expect(!(std.mem.eql(u8, edge.from, "pkg/__init__.py") and std.mem.eql(u8, edge.to, "pkg/hidden.py")));
    var literal = try fixture.scan(a, .{ .python_initializers = .explicit, .python_star_reexports = false });
    defer literal.deinit();
    for (literal.edges()) |edge| try std.testing.expect(!(std.mem.eql(u8, edge.from, "pkg/__init__.py") and std.mem.eql(u8, edge.to, "pkg/impl.py")));
}

test "Python reexports and imports share one source read" {
    const Reader = struct {
        const Self = @This();
        calls: usize = 0,
        fn read(self: *Self, scratch: std.mem.Allocator, _: std.Io, name: []const u8) !?[]const u8 {
            self.calls += 1;
            const value = try scratch.dupe(u8, if (std.mem.eql(u8, name, "pkg/__init__.py")) "from .api import *" else if (std.mem.eql(u8, name, "pkg/api.py")) "from .impl import Public as Exposed\n__all__ = ['Exposed']" else "");
            return value;
        }
    };
    var reader: Reader = .{};
    var graph = try g.scan(a, std.testing.io, &.{ "pkg/__init__.py", "pkg/api.py", "pkg/impl.py" }, &reader, Reader.read, .{ .python_initializers = .explicit });
    defer graph.deinit();
    try f.edge(&graph, "pkg/__init__.py", "pkg/impl.py", .import, 1);
    try std.testing.expectEqual(3, reader.calls);
}

test "imports in TYPE_CHECKING blocks are type-only, nested blocks included and else branches not" {
    const source =
        \\from typing import TYPE_CHECKING
        \\import typing
        \\import a
        \\if TYPE_CHECKING:
        \\    import b
        \\    from c import (X,
        \\        Y)
        \\    if sys.version_info >= (3, 8):
        \\        import d
        \\    else:
        \\        import e
        \\else:
        \\    import f
        \\if typing.TYPE_CHECKING: import g
        \\import h
        \\def fn():
        \\    if TYPE_CHECKING:
        \\        import i
        \\    import j
        \\    x = importlib.import_module("k") if TYPE_CHECKING else None
        \\
    ;
    var items: std.ArrayList(f.Item) = .empty;
    defer items.deinit(a);
    try items.append(a, .{ .path = "m.py", .text = source });
    const names = [_][]const u8{ "a.py", "b.py", "c.py", "d.py", "e.py", "f.py", "g.py", "h.py", "i.py", "j.py", "k.py" };
    for (names) |name| try items.append(a, .{ .path = name });
    var graph = try (f.Fixture{ .items = items.items }).scan(a, .{});
    defer graph.deinit();
    for ([_][]const u8{ "b.py", "c.py", "d.py", "e.py", "g.py", "i.py" }) |to| try f.edge(&graph, "m.py", to, .type_only, 1);
    for ([_][]const u8{ "a.py", "f.py", "h.py", "j.py" }) |to| try f.edge(&graph, "m.py", to, .import, 1);
    try f.edge(&graph, "m.py", "k.py", .dynamic, 1);
    // import-linter's exclude_type_checking_imports: the static graph alone.
    var static = try (f.Fixture{ .items = items.items }).scan(a, .{ .kinds = &.{.import} });
    defer static.deinit();
    try std.testing.expectEqual(4, static.edges().len);
}

test "importlib.import_module and __import__ with literal names are dynamic edges" {
    var graph = try (f.Fixture{ .items = &.{
        .{ .path = "app.py", .text =
        \\import importlib
        \\m1 = importlib.import_module("pkg.mod")
        \\m2 = importlib.import_module(".sib", package="pkg")
        \\m3 = importlib.import_module("..up", "pkg.sub")
        \\m4 = __import__("other", globals(), locals(), [], 0)
        \\m5 = importlib.import_module(name)
        \\m6 = importlib.import_module(".rel")
        \\m7 = __import__("..rel")
        },
        .{ .path = "pkg/__init__.py" },
        .{ .path = "pkg/mod.py" },
        .{ .path = "pkg/sib.py" },
        .{ .path = "pkg/up.py" },
        .{ .path = "pkg/sub/__init__.py" },
        .{ .path = "other.py" },
    } }).scan(a, .{});
    defer graph.deinit();
    for ([_][]const u8{ "pkg/mod.py", "pkg/sib.py", "pkg/up.py", "other.py" }) |to| try f.edge(&graph, "app.py", to, .dynamic, 1);
    try std.testing.expectEqual(3, graph.unsupported().len);
    for (graph.unsupported()) |record| try std.testing.expect(record.expression == .python_importlib or record.expression == .python_import);
}
