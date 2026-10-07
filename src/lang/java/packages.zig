//! Java files by the package they declare, recovered once for imports too.
const tokens_module = @import("../../tokens.zig");
const diagnostic_module = @import("../../scan/diagnostic.zig");
const path_module = @import("../../path.zig");
const std = @import("std");
const java = @import("../java.zig");
const t = @import("../../types.zig");

pub const Packages = std.StringHashMapUnmanaged(std.ArrayList([]const u8));

/// Each selected `.java` file under its declared package, in path order; a
/// file without a declaration is in the unnamed package, which no import
/// can name, and `package-info.java` and `module-info.java` declare no type.
/// Recoveries are kept in `cached` for the import pass.
pub fn index(arena: std.mem.Allocator, gpa: std.mem.Allocator, strings: std.mem.Allocator, paths: []const []const u8, context: anytype, comptime read: anytype, cached: []?t.Recovery, progress: *diagnostic_module.Progress, recorder: *tokens_module.Recorder) (diagnostic_module.ReadError(read) || error{OutOfMemory})!Packages {
    progress.at(.java_packages, null);
    var out: Packages = .empty;
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    for (paths, 0..) |file, file_index| {
        if (!std.mem.endsWith(u8, file, ".java")) continue;
        const base = path_module.base(file);
        // Package and module descriptors declare no type an import can name.
        const descriptor = std.mem.eql(u8, base, "package-info.java") or std.mem.eql(u8, base, "module-info.java");
        const s = scratch.allocator();
        defer _ = scratch.reset(.retain_capacity);
        const source = (try read(context, s, file)) orelse continue;
        progress.at(.java_packages, file);
        const tokens = try recorder.lex(java, s, file_index, file, .java, source);
        const recovery = java.recoverTokens(s, source, tokens) catch |err| {
            try progress.tolerate(err);
            cached[file_index] = .{};
            continue;
        };
        cached[file_index] = try recovery.clone(arena, strings);
        if (recovery.package.len == 0 or descriptor) continue;
        const entry = try out.getOrPut(arena, cached[file_index].?.package);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(arena, file);
    }
    progress.at(.java_packages, null);
    return out;
}
