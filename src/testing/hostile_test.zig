//! Scanning time grows with the input, not with its square: each case
//! repeats one opener whose close never comes, which a reader searching to
//! the end for every opener would take quadratic time over.
const std = @import("std");
const builtin = @import("builtin");
const aegis = @import("aegis");
const f = @import("support.zig");
const a = std.testing.allocator;

const Case = struct { path: []const u8, head: []const u8 = "", unit: []const u8, tail: []const u8 = "" };
const cases = [_]Case{
    .{ .path = "a.md", .unit = "[[" },
    .{ .path = "a.md", .unit = "](<" },
    .{ .path = "a.md", .unit = "`x" },
    .{ .path = "a.md", .unit = "``x`" },
    .{ .path = "pom.xml", .head = "<project><dependencies><dependency><groupId>", .unit = "&", .tail = "</groupId></dependency></dependencies></project>" },
    .{ .path = "a.c", .unit = "R\"" },
    .{ .path = "a.c", .unit = "#include \"" },
    .{ .path = "a.zig", .unit = "@import(" },
    .{ .path = "a.zig", .unit = "x = @import(\"y\") " },
    .{ .path = "a.ts", .unit = "import(" },
    .{ .path = "a.ts", .unit = "require(" },
    .{ .path = "a.ts", .unit = "import {" },
    .{ .path = "a.ts", .unit = "`${" },
    .{ .path = "a.py", .unit = "from (" },
    .{ .path = "a.py", .unit = "import (" },
    .{ .path = "a.py", .unit = "importlib.import_module(" },
    .{ .path = "a.go", .unit = "import (" },
    .{ .path = "a.rs", .unit = "use {" },
    .{ .path = "a.rs", .unit = "use a::{" },
    .{ .path = "a.rs", .head = "use ", .unit = "a::{" },
    .{ .path = "a.rs", .unit = "r#\"" },
    .{ .path = "a.nim", .unit = "import [" },
    .{ .path = "a.nim", .unit = "fmt\"" },
    .{ .path = "a.nim", .unit = "import a/[" },
    .{ .path = "A.java", .unit = "import " },
    .{ .path = "A.java", .unit = "Class.forName(" },
    .{ .path = "build.gradle", .unit = "dependencies {" },
    .{ .path = "build.gradle", .unit = "\"${" },
    .{ .path = "build.gradle.kts", .unit = "dependencies { implementation(" },
    .{ .path = "Cargo.toml", .head = "[dependencies]\n", .unit = "a.b = '" },
    .{ .path = "pyproject.toml", .head = "[project]\ndependencies = [", .unit = "{" },
    .{ .path = "go.mod", .head = "module x\n", .unit = "require " },
    .{ .path = "x.nimble", .unit = "requires " },
    .{ .path = "tsconfig.json", .unit = "{\"extends\":" },
};

/// Windows charges a thread's CPU time only at its scheduler's tick, about
/// 15.6 ms, so a short scan reads 0 there; its cycle count, the call
/// QueryThreadCycleTime makes, is exact. Linux and macOS keep the thread's CPU
/// time in nanoseconds.
const counts_cycles = builtin.os.tag == .windows;
const CycleTag = struct {};
/// What a scan costs: the thread's cycles where the system counts them, its
/// CPU time elsewhere.
const Cost = if (counts_cycles) aegis.units.Count(CycleTag, u64) else aegis.units.Duration(.nanosecond, u64);
/// A reading of what the thread has spent: a cycle count, or an instant of its
/// CPU clock.
const Reading = if (counts_cycles) Cost else aegis.units.Instant(std.Io.Clock.cpu_thread, .nanosecond, u64);

/// The work this thread has done so far, counted in the finest unit the
/// system keeps per thread: what the scan itself costs, whatever else the
/// machine runs (the wall clock counts other processes' turns too, and a
/// loaded machine failed this property on linear work).
fn spent(io: std.Io) !Reading {
    if (counts_cycles) {
        const windows = std.os.windows;
        var cycles: extern struct { accumulated: u64, current: u64 } = undefined;
        const status = windows.ntdll.NtQueryInformationThread(windows.GetCurrentThread(), .CycleTime, &cycles, @sizeOf(@TypeOf(cycles)), null);
        if (status != .SUCCESS) return error.CycleCountUnreadable;
        return .fromRaw(cycles.accumulated);
    }
    return Reading.fromTimestamp(std.Io.Timestamp.now(io, .cpu_thread), .exact);
}

/// What the thread spent from one reading to a later one.
fn between(start: Reading, end: Reading) !Cost {
    return if (counts_cycles) end.sub(start) else start.durationTo(end);
}

/// The cost a measurement can show for no work at all: none for a cycle
/// count, a few clock steps for a CPU clock.
const slack: Cost = if (counts_cycles) .fromRaw(0) else .literal("5ms");

fn run(case: Case, units: usize) !Cost {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(a);
    try text.appendSlice(a, case.head);
    for (0..units) |_| try text.appendSlice(a, case.unit);
    try text.appendSlice(a, case.tail);
    const fixture: f.Fixture = .{ .items = &.{.{ .path = case.path, .text = text.items }} };
    const io = std.testing.io;
    var best: ?Cost = null;
    for (0..3) |_| {
        const start = try spent(io);
        if (fixture.scan(a, .{ .kinds = &.{ .import, .type_only, .dynamic, .@"test", .link, .asset } })) |graph| {
            var owned = graph;
            owned.deinit();
        } else |err| switch (err) {
            error.OutOfMemory => return err,
            else => {},
        }
        const cost = try between(start, try spent(io));
        if (best == null or cost.compare(best.?) == .lt) best = cost;
    }
    return best.?;
}

test "property: scan time grows linearly with repeated unclosed openers" {
    for (cases) |case| {
        const small = 32 * 1024 / case.unit.len;
        const short = try run(case, small);
        const long = try run(case, small * 16);
        // Sixteen times the input costs sixteen times as much when the work is
        // linear and 256 when it is quadratic: a ceiling of 64 leaves four times
        // either way for caches and the system's own noise; the slack absorbs
        // a clock's resolution on a fast run.
        if (long.compare(try (try short.mul(64)).add(slack)) == .gt) {
            std.log.err("{s}: {d} for {d} openers, {d} for {d}", .{ case.path, short.raw(), small, long.raw(), small * 16 });
            return error.TestQuadraticTime;
        }
    }
}
