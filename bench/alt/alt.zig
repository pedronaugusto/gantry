//! Zig's own parser for what gantry recovers from Zig: `std.zig.Ast` parses
//! a whole file, and `@import` calls are counted from its nodes; for
//! `build.zig.zon` it parses ZON and counts the root `.dependencies` fields.
//! Same output rows as bench/ops.
const std = @import("std");
const Ast = std.zig.Ast;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.ExpectedWorkloadAndFile;
    const workload: []const u8 = args[1];
    const zon = std.mem.eql(u8, workload, "manifests/build.zig.zon");
    if (!zon and !std.mem.eql(u8, workload, "imports/zig")) return error.UnknownWorkload;
    const source = try std.Io.Dir.cwd().readFileAllocOptions(io, args[2], gpa, .unlimited, .of(u8), 0);
    defer gpa.free(source);
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const w = &stdout.interface;
    const Ctx = struct {
        gpa: std.mem.Allocator,
        source: [:0]const u8,
        zon: bool,
        count: usize = 0,
        fn op(c: *@This()) !void {
            var tree = try Ast.parse(c.gpa, c.source, if (c.zon) .zon else .zig);
            defer tree.deinit(c.gpa);
            if (tree.errors.len != 0) return error.ParseError;
            c.count = if (c.zon) try dependencies(&tree) else imports(&tree);
        }
    };
    var ctx: Ctx = .{ .gpa = gpa, .source = source, .zon = zon };
    try ctx.op();
    const side = if (zon) "zig-std-zon" else "zig-std-ast";
    if (init.environ_map.get("BENCH_SMOKE") != null) {
        try w.print("{s}\t{s}\tns_per_op\t0\tns\n", .{ side, workload });
    } else {
        var iterations: usize = 0;
        const start = std.Io.Clock.awake.now(io);
        var elapsed: i96 = 0;
        while (iterations < 3 or elapsed < 200 * std.time.ns_per_ms) {
            try ctx.op();
            iterations += 1;
            elapsed = start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;
        }
        try w.print("{s}\t{s}\tns_per_op\t{d:.3}\tns\n", .{ side, workload, @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations)) });
        try w.print("{s}\t{s}\titerations\t{d}\titerations\n", .{ side, workload, iterations });
    }
    try w.print("{s}\t{s}\tsource\t{d}\tbytes\n", .{ side, workload, source.len });
    try w.print("{s}\t{s}\t{s}\t{d}\tcount\n", .{ side, workload, if (zon) "dependencies" else "imports", ctx.count });
    try w.flush();
}

fn imports(tree: *const Ast) usize {
    var count: usize = 0;
    for (tree.nodes.items(.tag), 0..) |tag, i| switch (tag) {
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
            const node: Ast.Node.Index = @enumFromInt(i);
            if (std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@import")) count += 1;
        },
        else => {},
    };
    return count;
}

fn dependencies(tree: *const Ast) !usize {
    var buffer: [2]Ast.Node.Index = undefined;
    const root = tree.fullStructInit(&buffer, tree.rootDecls()[0]) orelse return error.NotAStruct;
    for (root.ast.fields) |field| {
        // A field's name is the identifier two tokens before its value: `.name = value`.
        if (!std.mem.eql(u8, tree.tokenSlice(tree.firstToken(field) - 2), "dependencies")) continue;
        var inner: [2]Ast.Node.Index = undefined;
        const deps = tree.fullStructInit(&inner, field) orelse return error.NotAStruct;
        return deps.ast.fields.len;
    }
    return 0;
}
