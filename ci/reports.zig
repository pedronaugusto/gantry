//! Validate the report fixtures with the downstream renderers and SARIF schema.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, ".zig-cache/reports");
    try cwd.writeFile(io, .{ .sub_path = ".zig-cache/reports/puppeteer.json", .data = "{\"args\":[\"--no-sandbox\"]}\n" });
    try command(a, io, &.{ "curl", "-fsSL", "https://json.schemastore.org/sarif-2.1.0.json", "-o", ".zig-cache/reports/sarif-schema.json" });
    var dir = try cwd.openDir(io, "src/testing/golden", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const path = try std.fs.path.join(a, &.{ "src/testing/golden", entry.name });
        if (std.mem.endsWith(u8, path, ".dot")) {
            try command(a, io, &.{ "dot", "-Tsvg", path, "-o", ".zig-cache/reports/dot.svg" });
        } else if (std.mem.endsWith(u8, path, ".mmd")) {
            try command(a, io, &.{ "npx", "-y", "-p", "@mermaid-js/mermaid-cli@11", "mmdc", "-q", "-p", ".zig-cache/reports/puppeteer.json", "-i", path, "-o", ".zig-cache/reports/mermaid.svg" });
        } else if (std.mem.endsWith(u8, path, ".json")) {
            const data = try cwd.readFileAlloc(io, path, a, .limited(8 * 1024 * 1024));
            _ = try std.json.parseFromSlice(std.json.Value, a, data, .{});
        } else if (std.mem.endsWith(u8, path, ".sarif")) {
            try command(a, io, &.{ "jsonschema", "--instance", path, ".zig-cache/reports/sarif-schema.json" });
        }
    }
}

fn command(a: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const result = try std.process.run(a, io, .{ .argv = argv });
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("report tool failed: {s}\n{s}{s}\n", .{ argv[0], result.stdout, result.stderr });
        return error.ReportValidationFailed;
    }
}
