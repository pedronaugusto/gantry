//! The Zig front end over a scan's files, started before the scan needs it.
//! Files are read one after another, as a reader requires, and handed to as
//! many tasks as `io` runs; the scan takes each file's recovery in path order
//! when it reaches the file, so the graph does not depend on the schedule.
//! The front end costs several times what a lexer does, and this keeps that
//! work off the scan's own path.
const std = @import("std");
const tokens_module = @import("../../tokens.zig");
const diagnostic_module = @import("../../scan/diagnostic.zig");
const t = @import("../../types.zig");
const zig = @import("../zig.zig");
const Recoveries = @This();

/// Source bytes held for tasks by default; the files past them are recovered,
/// one at a time, when the scan reaches them.
const resident_limit = 128 << 20;
/// Fewer files than this are recovered by the calling task before `start`
/// returns: they would not repay the tasks, and a caller's allocator need
/// not be thread safe for a handful of files.
const parallel_threshold = 16;
const none = std.math.maxInt(u32);

const Item = struct {
    path: []const u8,
    bytes: []const u8,
    /// The front end's work and its result live here until the scan takes it.
    arena: std.heap.ArenaAllocator,
    result: zig.RecoverError!t.Recovery = error.OutOfMemory,
    /// Zero until `result` is set; tasks wake the scan through it.
    done: std.atomic.Value(u32) = .init(0),
    taken: bool = false,
};

/// What taking a recovery fails with besides memory: the scan being cancelled
/// while it waits for a task.
pub const Error = error{ OutOfMemory, Canceled };

gpa: std.mem.Allocator,
io: std.Io,
/// Source bytes to hold before the rest are left to the scan.
limit: usize = resident_limit,
/// Copies of the sources, which the reader's own buffers do not outlive.
held: std.heap.ArenaAllocator,
items: []Item = &.{},
/// A path's position in the scan to its item, or `none`.
slot: []u32,
next: std.atomic.Value(usize) = .init(0),
stop: std.atomic.Value(bool) = .init(false),
group: std.Io.Group = .init,

pub fn init(gpa: std.mem.Allocator, io: std.Io, files: usize) std.mem.Allocator.Error!Recoveries {
    const slot = try gpa.alloc(u32, files);
    @memset(slot, none);
    return .{ .gpa = gpa, .io = io, .held = .init(gpa), .slot = slot };
}

/// Stops the tasks, waits for them, and releases every file not taken.
pub fn deinit(r: *Recoveries) void {
    r.stop.store(true, .monotonic);
    r.group.cancel(r.io);
    for (r.items) |*item| if (!item.taken) item.arena.deinit();
    r.gpa.free(r.items);
    r.gpa.free(r.slot);
    r.held.deinit();
    r.* = undefined;
}

/// Reads every `.zig` file in `paths` and starts recovering them. A file the
/// reader has no bytes for has no item. The token rules see each file's
/// lexer stream here, since the facts are glint's and the rules' are not.
/// Tasks allocate from `gpa`, which must then be thread safe, as the `io`
/// that runs them requires of its own allocator.
pub fn start(r: *Recoveries, paths: []const []const u8, context: anytype, comptime read: anytype, progress: *diagnostic_module.Progress, recorder: *tokens_module.Recorder) (diagnostic_module.ReadError(read) || error{OutOfMemory})!void {
    var scratch: std.heap.ArenaAllocator = .init(r.gpa);
    defer scratch.deinit();
    var items: std.ArrayList(Item) = .empty;
    errdefer {
        for (items.items) |*item| item.arena.deinit();
        items.deinit(r.gpa);
    }
    var indexes: std.ArrayList(u32) = .empty;
    defer indexes.deinit(r.gpa);
    var held: usize = 0;
    for (paths, 0..) |path, index| {
        if (!std.mem.eql(u8, std.Io.Dir.path.extension(path), ".zig")) continue;
        if (held >= r.limit) break;
        const s = scratch.allocator();
        defer _ = scratch.reset(.{ .retain_with_limit = 1 << 20 });
        const text = (try read(context, s, path)) orelse continue;
        progress.at(.imports, path);
        if (recorder.wants(index)) _ = try recorder.lex(zig, s, index, path, .zig, text);
        const bytes = try r.held.allocator().dupe(u8, text);
        held += bytes.len;
        try items.append(r.gpa, .{ .path = path, .bytes = bytes, .arena = .init(r.gpa) });
        try indexes.append(r.gpa, @intCast(index)); // safe: a path position of a scan whose files fit u32.
    }
    r.items = try items.toOwnedSlice(r.gpa);
    for (indexes.items, 0..) |index, at| r.slot[index] = @intCast(at); // safe: as above.
    if (r.items.len < parallel_threshold) return r.work();
    const tasks = @min(std.Thread.getCpuCount() catch 1, r.items.len);
    var spawned: usize = 0;
    while (spawned < tasks) : (spawned += 1) r.group.concurrent(r.io, work, .{r}) catch break;
    // With no task to run on, the calling task recovers every file now.
    if (spawned == 0) r.work();
}

/// One task: files are claimed in path order until none is left.
fn work(r: *Recoveries) void {
    while (!r.stop.load(.monotonic)) {
        const at = r.next.fetchAdd(1, .monotonic);
        if (at >= r.items.len) return;
        const item = &r.items[at];
        item.result = zig.recover(r.gpa, item.arena.allocator(), item.bytes);
        item.done.store(1, .release);
        r.io.futexWake(u32, &item.done.raw, 1);
    }
}

/// The recovery of the file at `index` of the scan's paths, waiting for the
/// task that makes it; null for a file this has no item for. The specs are in
/// `arena` and their names in `strings`. A file the front end rejects is a
/// record in `progress` and has an empty recovery. Each file is taken once.
pub fn take(r: *Recoveries, arena: std.mem.Allocator, strings: std.mem.Allocator, index: usize, progress: *diagnostic_module.Progress) Error!?t.Recovery {
    const at = r.slot[index];
    if (at == none) return null;
    const item = &r.items[at];
    std.debug.assert(!item.taken);
    while (item.done.load(.acquire) == 0) try r.io.futexWait(u32, &item.done.raw, 0);
    item.taken = true;
    defer item.arena.deinit();
    progress.at(.imports, item.path);
    const recovery = item.result catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidSource => {
            try progress.tolerate(err);
            return .{};
        },
    };
    const taken = try recovery.clone(arena, strings);
    return taken;
}
