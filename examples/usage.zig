const std = @import("std");
const gantry = @import("gantry");

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    // --- README:usage ---
    const paths = &.{ "src/main.zig", "src/store.zig", "src/model.zig" };
    var graph = try gantry.scan(gpa, paths, {}, read, .{});
    defer graph.deinit();

    for (graph.edges()) |edge| {
        std.debug.print("{s} -> {s} ({d})\n", .{ edge.from, edge.to, edge.count });
    }
    var analysis = try graph.analyze(gpa);
    defer analysis.deinit();
    for (analysis.layers()) |layer| {
        std.debug.print("{s}: depth {d}\n", .{ layer.path, layer.depth });
    }

    const findings = try graph.check(gpa, .{
        .nothing_imports = &.{.{ .name = "entry files", .to = "**/main.zig" }},
        .no_cycles = "no cycles",
    });
    defer gpa.free(findings);
    for (findings) |finding| std.debug.print("{s}: {s}\n", .{ finding.rule, @tagName(finding.reason) });
    // --- README:usage ---
}

// Replace this with bytes from your own file store. The supplied allocator
// lives for one file; returned bytes are consumed before the next read.
fn read(_: void, path: []const u8, _: std.mem.Allocator) !?[]const u8 {
    if (std.mem.eql(u8, path, "src/main.zig")) return "const store = @import(\"store.zig\");";
    if (std.mem.eql(u8, path, "src/store.zig")) return "const model = @import(\"model.zig\");";
    return "";
}
