const std = @import("std");
const gantry = @import("gantry");
const api = @import("api.zig");

// The caller supplies one newline-separated file universe, shared with rivals.
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 3) return error.ExpectedRepositoryAndPaths;
    var dir = try std.Io.Dir.cwd().openDir(io, args[1], .{});
    defer dir.close(io);
    const input = try std.Io.Dir.cwd().readFileAlloc(io, args[2], a, .unlimited);
    var selected: std.StringHashMapUnmanaged(void) = .empty;
    var directories: std.StringHashMapUnmanaged(void) = .empty;
    var lines = std.mem.tokenizeScalar(u8, input, '\n');
    while (lines.next()) |line| {
        try selected.put(a, line, {});
        var parent = gantry.path.dir(line);
        while (parent.len > 0) : (parent = gantry.path.dir(parent)) try directories.put(a, parent, {});
    }
    var paths = try gantry.walk(init.gpa, io, dir, Selection{ .files = &selected, .directories = &directories }, Selection.keep);
    defer paths.deinit();
    if (api.items(&paths).len != selected.count()) return error.MissingSelectedFile;
    var graph = try gantry.scan(init.gpa, api.items(&paths), gantry.DirReader{ .io = io, .dir = dir }, gantry.DirReader.read, .{ .manifests = false });
    defer graph.deinit();
    if (api.unread(&graph).len != 0) return error.UnreadFiles;
    var buffer: [65536]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(io, &buffer);
    for (api.edges(&graph)) |edge| try writer.interface.print("E\t{s}\t{s}\n", .{ edge.from, edge.to });
    for (api.references(&graph)) |ref| try writer.interface.print("R\t{s}\t{d}\t{d}\t{s}\n", .{ ref.from, ref.offset, @intFromBool(ref.resolved), ref.name });
    try writer.interface.flush();
}

const Selection = struct {
    files: *const std.StringHashMapUnmanaged(void),
    directories: *const std.StringHashMapUnmanaged(void),
    fn keep(self: Selection, path: []const u8, kind: std.Io.File.Kind) bool {
        return if (kind == .directory) self.directories.contains(path) else self.files.contains(path);
    }
};
