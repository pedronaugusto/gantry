const std = @import("std");
const gantry = @import("gantry");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    // --- README:usage ---
    const paths = &.{ "src/main.zig", "src/store.zig", "src/model.zig" };
    var graph = try gantry.scan(gpa, io, paths, {}, read, .{});
    defer graph.deinit();

    for (graph.edges()) |edge| {
        std.log.info("{s} -> {s} ({d})", .{ edge.from, edge.to, edge.count });
    }
    var analysis = try graph.analyze(gpa);
    defer analysis.deinit();
    for (analysis.layers()) |layer| {
        std.log.info("{s}: depth {d}", .{ layer.path, layer.depth });
    }

    // A file the scan could not read as its format is a record, not an error.
    for (graph.invalid()) |file| {
        std.log.info("{s}: {s}", .{ file.path, @errorName(file.cause) });
    }

    var findings = try graph.check(gpa, .{
        .nothing_imports = &.{.{ .name = "entry files", .to = "**/main.zig" }},
        .no_cycles = "no cycles",
    });
    defer findings.deinit();
    for (findings.items()) |finding| std.log.info("{s}: {s}", .{ finding.rule, @tagName(finding.reason) });
    // --- README:usage ---
    var diagnosed = try scanDiagnosed(gpa, io, paths);
    defer diagnosed.deinit();
}

fn scanDiagnosed(gpa: std.mem.Allocator, io: std.Io, paths: []const []const u8) !gantry.Graph {
    // --- README:diagnostic ---
    var diagnostic = gantry.Diagnostics.init(gpa);
    defer diagnostic.deinit();
    return gantry.scan(gpa, io, paths, {}, read, .{ .diagnostics = &diagnostic }) catch |cause| {
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
fn read(_: std.mem.Allocator, _: std.Io, _: void, path: []const u8) !?[]const u8 {
    if (std.mem.eql(u8, path, "src/main.zig")) return "const store = @import(\"store.zig\");";
    if (std.mem.eql(u8, path, "src/store.zig")) return "const model = @import(\"model.zig\");";
    return "";
}
