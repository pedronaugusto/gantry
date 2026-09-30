const std = @import("std");
const g = @import("gantry.zig");
const f = @import("test_support.zig");
const a = std.testing.allocator;

test "Python initializer policy distinguishes direct imports and modulefinder ancestors" {
    const fixture: f.Fixture = .{ .items = &.{
        .{ .path = "pkg/__init__.py" },                                                                                          .{ .path = "pkg/sub/__init__.py" },
        .{ .path = "pkg/sub/a.py", .text = "from . import child\nfrom pkg.sub import child\nfrom pkg.sub.child import Symbol" }, .{ .path = "pkg/sub/child.py" },
    } };
    var direct = try fixture.scan(a, .{ .python_initializers = .explicit });
    defer direct.deinit();
    try std.testing.expectEqual(1, direct.edges.len);
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
    for (graph.edges) |edge| try std.testing.expect(!(std.mem.eql(u8, edge.from, "pkg/__init__.py") and std.mem.eql(u8, edge.to, "pkg/hidden.py")));
    var literal = try fixture.scan(a, .{ .python_initializers = .explicit, .python_star_reexports = false });
    defer literal.deinit();
    for (literal.edges) |edge| try std.testing.expect(!(std.mem.eql(u8, edge.from, "pkg/__init__.py") and std.mem.eql(u8, edge.to, "pkg/impl.py")));
}
