const std = @import("std");
const gantry = @import("gantry");

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    // --- README:usage ---
    const paths = &.{ "src/main.zig", "src/store.zig", "src/model.zig" };
    var graph = try gantry.scan(gpa, paths, {}, read, .{});
    defer graph.deinit();

    for (graph.edges()) |edge| {
        std.log.info("{s} -> {s} ({d})", .{ edge.from, edge.to, edge.count });
    }
    var analysis = try graph.analyze(gpa);
    defer analysis.deinit();
    for (analysis.layers()) |layer| {
        std.log.info("{s}: depth {d}", .{ layer.path, layer.depth });
    }

    const findings = try graph.check(gpa, .{
        .nothing_imports = &.{.{ .name = "entry files", .to = "**/main.zig" }},
        .no_cycles = "no cycles",
    });
    defer gpa.free(findings);
    for (findings) |finding| std.log.info("{s}: {s}", .{ finding.rule, @tagName(finding.reason) });
    // --- README:usage ---
    var diagnosed = try scanDiagnosed(gpa, paths);
    defer diagnosed.deinit();
}

fn scanDiagnosed(gpa: std.mem.Allocator, paths: []const []const u8) !gantry.Graph {
    // --- README:diagnostic ---
    var diagnostic = gantry.ScanDiagnostic.init(gpa);
    defer diagnostic.deinit();
    return gantry.scanWithDiagnostic(gpa, paths, {}, read, .{}, &diagnostic) catch |cause| {
        if (diagnostic.failure) |failure| {
            std.log.info("{s}: {s}: {s}", .{
                failure.path orelse "<scan>",
                @tagName(failure.phase),
                @errorName(failure.cause),
            });
        }
        return cause;
    };
    // --- README:diagnostic ---
}

// Replace this with bytes from your own file store. The supplied allocator
// lives for one file; returned bytes are consumed before the next read.
fn read(_: std.mem.Allocator, _: void, path: []const u8) !?[]const u8 {
    if (std.mem.eql(u8, path, "src/main.zig")) return "const store = @import(\"store.zig\");";
    if (std.mem.eql(u8, path, "src/store.zig")) return "const model = @import(\"model.zig\");";
    return "";
}
