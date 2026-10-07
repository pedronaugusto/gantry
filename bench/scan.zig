//! The scan of a directory: `scan <dir> [rounds]` lists it, then times
//! complete scans from disk and from memory, analysis and aggregation.
const std = @import("std");
const gantry = @import("gantry");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const w = &stdout.interface;
    defer w.flush() catch {};
    if (args.len < 2 or args.len > 3) return error.ExpectedCorpusDirectory;
    var dir = try std.Io.Dir.cwd().openDir(io, args[1], .{ .iterate = true });
    defer dir.close(io);
    const rounds: usize = if (args.len == 3) try std.fmt.parseInt(usize, args[2], 10) else 5;
    const listing = benchmarkNow(io);
    var paths = try gantry.walk(gpa, io, dir, {}, keep);
    defer paths.deinit();
    const listed = benchmarkNow(io);
    try w.print("files {d}, listing {d:.3} ms\n", .{ paths.items().len, ms(listing, listed) });
    // Five complete scans. Data generation and path listing are outside
    // the scan measurement; file opens and reads are inside it.
    for (0..rounds) |round| {
        const start = benchmarkNow(io);
        var graph = try gantry.scan(gpa, io, paths.items(), gantry.DirReader{ .dir = dir }, gantry.DirReader.read, .{ .python_roots = &.{"py"} });
        defer graph.deinit();
        const scanned = benchmarkNow(io);
        var analysis = try graph.analyze(gpa);
        defer analysis.deinit();
        const analyzed = benchmarkNow(io);
        var dirs = try graph.aggregate(gpa, 2);
        defer dirs.deinit();
        const aggregated = benchmarkNow(io);
        // The corpus's TypeScript pair is a static and a dynamic import.
        var dynamic: usize = 0;
        for (graph.edges()) |edge| dynamic += @intFromBool(edge.kind == .dynamic);
        try w.print("round {d}: scan {d:.3} ms, analyze {d:.3} ms, aggregate {d:.3} ms; edges {d}, references {d}, dependencies {d}, dynamic {d}, SCCs {d}, cycles {d}\n", .{
            round, ms(start, scanned), ms(scanned, analyzed), ms(analyzed, aggregated), graph.edges().len, graph.references().len, graph.dependencies().len, dynamic, analysis.components().len, analysis.cycles().len,
        });
    }
    var memory: std.heap.ArenaAllocator = .init(gpa);
    defer memory.deinit();
    const ma = memory.allocator();
    var store: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (paths.items()) |p| try store.put(ma, p, try dir.readFileAlloc(io, p, ma, .unlimited));
    for (0..rounds) |round| {
        const start = benchmarkNow(io);
        var graph = try gantry.scan(gpa, io, paths.items(), &store, readMemory, .{ .python_roots = &.{"py"} });
        defer graph.deinit();
        const end = benchmarkNow(io);
        try w.print("memory round {d}: scan {d:.3} ms; edges {d}\n", .{ round, ms(start, end), graph.edges().len });
    }
}
fn keep(_: void, _: []const u8, _: std.Io.File.Kind) bool {
    return true;
}
fn ms(start: std.Io.Timestamp, end: std.Io.Timestamp) f64 {
    return @as(f64, @floatFromInt(start.durationTo(end).nanoseconds)) / 1_000_000;
}

fn readMemory(store: *const std.StringHashMapUnmanaged([]const u8), _: std.mem.Allocator, _: std.Io, p: []const u8) error{}!?[]const u8 {
    return store.get(p);
}

// Smoke exercises correctness without sampling a benchmark clock.
var smoke_ticks = std.atomic.Value(i64).init(0);
fn benchmarkNow(io: std.Io) std.Io.Timestamp {
    if (@import("bench_options").smoke) return .{ .nanoseconds = smoke_ticks.fetchAdd(1, .monotonic) };
    return std.Io.Clock.awake.now(io);
}
