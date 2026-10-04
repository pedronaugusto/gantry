const std = @import("std");
const g = @import("gantry.zig");
const f = @import("testing/test_support.zig");
const a = std.testing.allocator;

/// A Go module whose `app` files each import package `lib`, so every one
/// has an edge to every `lib` file; `big/big.go` is read between them.
const Module = struct {
    importers: usize,
    members: usize,
    big: []const u8 = "",
    counter: f.Peak = .{ .child = a },
    before_big: usize = 0,
    after_big: usize = 0,
    fn read(self: *Module, path: []const u8, s: std.mem.Allocator) !?[]const u8 {
        if (std.mem.eql(u8, path, "go.mod")) return "module example.org/m";
        if (std.mem.eql(u8, path, "big/big.go")) {
            self.before_big = self.counter.live;
            return self.big;
        }
        if (std.mem.eql(u8, path, "lib/l0.go") and self.after_big == 0) self.after_big = self.counter.live;
        if (std.mem.startsWith(u8, path, "app/")) return "package app\nimport \"example.org/m/lib\"\n";
        return try s.dupe(u8, "package lib\n");
    }
    /// The edges scanned, with the most bytes the scan held at once.
    fn scan(self: *Module) !struct { usize, usize } {
        var arena: std.heap.ArenaAllocator = .init(a);
        defer arena.deinit();
        const s = arena.allocator();
        var paths: std.ArrayList([]const u8) = .empty;
        try paths.append(s, "go.mod");
        if (self.big.len > 0) try paths.append(s, "big/big.go");
        for (0..self.importers) |i| try paths.append(s, try std.fmt.allocPrint(s, "app/a{d}.go", .{i}));
        for (0..self.members) |i| try paths.append(s, try std.fmt.allocPrint(s, "lib/l{d}.go", .{i}));
        var graph = try g.scan(self.counter.allocator(), paths.items, self, read, .{ .manifests = false });
        defer graph.deinit();
        return .{ graph.edges().len, self.counter.peak };
    }
};

test "scan holds edges outside graph storage until they are coalesced" {
    var module: Module = .{ .importers = 120, .members = 120 };
    const edges, const peak = try module.scan();
    try std.testing.expectEqual(120 * 120, edges);
    // The returned edges, and no outgrown copies of them beside it.
    try std.testing.expect(peak < 4 * edges * @sizeOf(g.Edge));
}

test "scan returns a large file's scratch before reading the next" {
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(a);
    try source.appendSlice(a, "package big\n");
    for (0..20_000) |_| try source.appendSlice(a, "var x = 1\n");
    var module: Module = .{ .importers = 1, .members = 1, .big = source.items };
    _ = try module.scan();
    const tokens = 100_002 * @sizeOf(@import("lexer.zig").Token);
    try std.testing.expect(module.counter.peak > tokens);
    try std.testing.expect(module.after_big - module.before_big < tokens / 2);
}
