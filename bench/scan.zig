const std = @import("std");
const gantry = @import("gantry");
const api = @import("api.zig");

pub fn main(init: std.process.Init) !void {
    const a = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2 or args.len > 3) return error.ExpectedCorpusDirectory;
    var dir = try std.Io.Dir.cwd().openDir(io, args[1], .{ .iterate = true });
    defer dir.close(io);
    const rounds: usize = if (args.len == 3) try std.fmt.parseInt(usize, args[2], 10) else 5;
    const listing = std.Io.Clock.awake.now(io);
    var paths = try gantry.walk(a, io, dir, {}, keep);
    defer paths.deinit();
    const listed = std.Io.Clock.awake.now(io);
    std.debug.print("files {d}, listing {d:.3} ms\n", .{ api.items(&paths).len, ms(listing, listed) });
    // Five complete scans. Data generation and path listing are outside
    // the scan measurement; file opens and reads are inside it.
    for (0..rounds) |round| {
        const start = std.Io.Clock.awake.now(io);
        var graph = try gantry.scan(a, api.items(&paths), gantry.DirReader{ .io = io, .dir = dir }, gantry.DirReader.read, .{ .python_roots = &.{"py"} });
        defer graph.deinit();
        const scanned = std.Io.Clock.awake.now(io);
        var analysis = try graph.analyze(a);
        defer analysis.deinit();
        const analyzed = std.Io.Clock.awake.now(io);
        var dirs = try graph.aggregate(a, 2);
        defer dirs.deinit();
        const aggregated = std.Io.Clock.awake.now(io);
        std.debug.print("round {d}: scan {d:.3} ms, analyze {d:.3} ms, aggregate {d:.3} ms; edges {d}, references {d}, dependencies {d}, SCCs {d}, cycles {d}\n", .{
            round, ms(start, scanned), ms(scanned, analyzed), ms(analyzed, aggregated), api.edges(&graph).len, api.references(&graph).len, api.dependencies(&graph).len, api.components(&analysis).len, api.cycles(&analysis).len,
        });
    }
    var memory: std.heap.ArenaAllocator = .init(a);
    defer memory.deinit();
    const ma = memory.allocator();
    var store: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (api.items(&paths)) |p| try store.put(ma, p, try dir.readFileAlloc(io, p, ma, .unlimited));
    for (0..rounds) |round| {
        const start = std.Io.Clock.awake.now(io);
        var graph = try gantry.scan(a, api.items(&paths), &store, memoryRead, .{ .python_roots = &.{"py"} });
        defer graph.deinit();
        const end = std.Io.Clock.awake.now(io);
        std.debug.print("memory round {d}: scan {d:.3} ms; edges {d}\n", .{ round, ms(start, end), api.edges(&graph).len });
    }
}
fn keep(_: void, _: []const u8, _: std.Io.File.Kind) bool {
    return true;
}
fn ms(start: std.Io.Timestamp, end: std.Io.Timestamp) f64 {
    return @as(f64, @floatFromInt(start.durationTo(end).nanoseconds)) / 1_000_000;
}

fn memoryRead(store: *const std.StringHashMapUnmanaged([]const u8), p: []const u8, _: std.mem.Allocator) !?[]const u8 {
    return store.get(p);
}
