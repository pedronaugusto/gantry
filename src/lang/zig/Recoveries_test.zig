const std = @import("std");
const diagnostic_module = @import("../../scan/diagnostic.zig");
const tokens_module = @import("../../tokens.zig");
const Recoveries = @import("Recoveries.zig");
const a = std.testing.allocator;

const Files = struct {
    texts: []const []const u8,
    fn read(self: *const Files, scratch: std.mem.Allocator, path: []const u8) error{OutOfMemory}!?[]const u8 {
        const index = std.fmt.parseInt(usize, path[0 .. path.len - 4], 10) catch return null;
        const text = try scratch.dupe(u8, self.texts[index]);
        return text;
    }
};

fn names(count: usize) ![]const []const u8 {
    const out = try a.alloc([]const u8, count);
    for (out, 0..) |*name, i| name.* = try a.print("{d}.zig", .{i});
    return out;
}
fn freeNames(list: []const []const u8) void {
    for (list) |name| a.free(name);
    a.free(list);
}

test "files past the limit have no item, and the others are taken once, in any order" {
    const texts = [_][]const u8{ "pub const a = @import(\"a.zig\");", "pub const b = @import(\"b.zig\");", "pub const c = @import(\"c.zig\");" };
    const paths = try names(texts.len);
    defer freeNames(paths);
    var r: Recoveries = try .init(a, std.testing.io, paths.len);
    defer r.deinit();
    r.limit = 1;
    var progress: diagnostic_module.Progress = .{ .diagnostic = null };
    var recorder: tokens_module.Recorder = .{};
    const files: Files = .{ .texts = &texts };
    try r.start(paths, &files, Files.read, &progress, &recorder);
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    try std.testing.expect(try r.take(arena.allocator(), arena.allocator(), 2, &progress) == null);
    try std.testing.expect(try r.take(arena.allocator(), arena.allocator(), 1, &progress) == null);
    const taken = (try r.take(arena.allocator(), arena.allocator(), 0, &progress)).?;
    try std.testing.expectEqual(1, taken.specs.len);
    try std.testing.expectEqualStrings("a.zig", taken.specs[0].name);
}

test "many files are recovered on tasks and taken in any order with what each file says" {
    const count = 64;
    var texts: [count][]const u8 = undefined;
    for (&texts, 0..) |*text, i| text.* = try a.print("const x{d} = @import(\"x{d}.zig\");\npub fn f() void {{}}\ntest {{ _ = x{d}; }}\n", .{ i, i, i });
    defer for (texts) |text| a.free(text);
    const paths = try names(count);
    defer freeNames(paths);
    var r: Recoveries = try .init(a, std.testing.io, paths.len);
    defer r.deinit();
    var progress: diagnostic_module.Progress = .{ .diagnostic = null };
    var recorder: tokens_module.Recorder = .{};
    const files: Files = .{ .texts = &texts };
    try r.start(paths, &files, Files.read, &progress, &recorder);
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    var i: usize = count;
    while (i > 0) {
        i -= 1;
        const taken = (try r.take(arena.allocator(), arena.allocator(), i, &progress)).?;
        try std.testing.expectEqual(1, taken.specs.len);
        try std.testing.expectEqualStrings(try arena.allocator().print("x{d}.zig", .{i}), taken.specs[0].name);
        try std.testing.expectEqual(.@"test", taken.specs[0].kind);
    }
}

test "files not taken are released with the recoveries" {
    const texts = [_][]const u8{ "pub const a = @import(\"a.zig\");", "pub const b = 1" };
    const paths = try names(texts.len);
    defer freeNames(paths);
    var r: Recoveries = try .init(a, std.testing.io, paths.len);
    defer r.deinit();
    var progress: diagnostic_module.Progress = .{ .diagnostic = null };
    var recorder: tokens_module.Recorder = .{};
    const files: Files = .{ .texts = &texts };
    try r.start(paths, &files, Files.read, &progress, &recorder);
}
