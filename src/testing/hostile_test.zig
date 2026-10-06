//! Scanning time grows with the input, not with its square: each case
//! repeats one opener whose close never comes, which a reader searching to
//! the end for every opener would take quadratic time over.
const std = @import("std");
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

fn run(case: Case, units: usize) !u64 {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(a);
    try text.appendSlice(a, case.head);
    for (0..units) |_| try text.appendSlice(a, case.unit);
    try text.appendSlice(a, case.tail);
    const fixture: f.Fixture = .{ .items = &.{.{ .path = case.path, .text = text.items }} };
    const io = std.testing.io;
    var best: u64 = std.math.maxInt(u64);
    for (0..3) |_| {
        const start = std.Io.Timestamp.now(io, .awake);
        if (fixture.scan(a, .{ .kinds = &.{ .import, .type_only, .dynamic, .@"test", .link, .asset } })) |graph| {
            var owned = graph;
            owned.deinit();
        } else |err| switch (err) {
            error.OutOfMemory => return err,
            else => {},
        }
        const took = start.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds;
        best = @min(best, @as(u64, @intCast(took)));
    }
    return best;
}

test "property: scan time grows linearly with repeated unclosed openers" {
    for (cases) |case| {
        const small = 32 * 1024 / case.unit.len;
        const short = try run(case, small);
        const long = try run(case, small * 4);
        // Four times the input takes four times as long when the work is
        // linear and sixteen when it is quadratic; the slack absorbs timer
        // noise on a fast run.
        if (long > 8 * short + 5 * std.time.ns_per_ms) {
            std.log.err("{s}: {d} us for {d} openers, {d} us for {d}", .{ case.path, short / 1000, small, long / 1000, small * 4 });
            return error.TestQuadraticTime;
        }
    }
}
