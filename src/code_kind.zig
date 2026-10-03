const std = @import("std");
const p = @import("path.zig");
const t = @import("types.zig");
pub fn file(language: t.Language, name: []const u8) bool {
    const base = p.base(name);
    return switch (language) {
        .go => std.mem.endsWith(u8, base, "_test.go"),
        .python => std.mem.startsWith(u8, base, "test_") or std.mem.endsWith(u8, base, "_test.py"),
        // Nimble runs `tests/**/t*.nim`; testament keeps the same layout.
        .nim => std.mem.startsWith(u8, base, "test") or (base[0] == 't' and (std.mem.startsWith(u8, name, "tests/") or std.mem.indexOf(u8, name, "/tests/") != null)),
        .javascript => blk: {
            var dirs = std.mem.splitScalar(u8, name, '/');
            while (dirs.next()) |dir| if (std.mem.eql(u8, dir, "__tests__")) break :blk true;
            const stem = base[0 .. base.len - std.fs.path.extension(base).len];
            break :blk std.mem.endsWith(u8, stem, ".test") or std.mem.endsWith(u8, stem, ".spec");
        },
        // Maven and Gradle source sets: `src/test`, `src/testFixtures`,
        // `src/integrationTest`, `src/androidTest`.
        .java => blk: {
            var dirs = std.mem.splitScalar(u8, p.dir(name), '/');
            var after_src = false;
            while (dirs.next()) |dir| {
                if (after_src and (std.mem.startsWith(u8, dir, "test") or std.mem.endsWith(u8, dir, "Test"))) break :blk true;
                after_src = std.mem.eql(u8, dir, "src");
            }
            break :blk false;
        },
        else => false,
    };
}
/// File-module declarations propagate cfg(test) through their descendants.
pub fn rustFiles(a: std.mem.Allocator, gpa: std.mem.Allocator, paths: []const []const u8, ctx: anytype, context: anytype, comptime read: anytype, cached: []?t.Recovery, strings: std.mem.Allocator, progress: *@import("scan_diagnostic.zig").Progress, recorder: *@import("tokens.zig").Recorder) !std.StringHashMapUnmanaged(void) {
    progress.at(.rust_tests, null);
    var marked: std.StringHashMapUnmanaged(void) = .empty;
    var declarations: std.ArrayList(t.Edge) = .empty;
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    for (paths, 0..) |from, index| {
        if (!std.mem.endsWith(u8, from, ".rs")) continue;
        const s = scratch.allocator();
        defer _ = scratch.reset(.retain_capacity);
        const text = (try read(context, from, s)) orelse continue;
        progress.at(.rust_tests, from);
        const rust = @import("lang/rust.zig");
        const tokens = try recorder.lex(rust, s, index, from, .rust, text);
        if (rust.testFileTokens(tokens)) try marked.put(a, from, {});
        const recovery = try rust.recoverTokens(s, text, tokens);
        if (cached.len > 0) cached[index] = try recovery.clone(a, strings);
        var resolver = ctx;
        resolver.allocator = s;
        for (recovery.specs) |spec| {
            if (spec.form != .rust_mod) continue;
            for (try resolver.targets(from, .rust, spec)) |to| try declarations.append(a, .{ .from = from, .to = ctx.files.getKey(to).?, .kind = spec.kind });
        }
    }
    progress.at(.rust_tests, null);
    var changed = true;
    while (changed) {
        changed = false;
        for (declarations.items) |edge| if (edge.kind == .@"test" or marked.contains(edge.from)) {
            const entry = try marked.getOrPut(a, edge.to);
            if (!entry.found_existing) changed = true;
        };
    }
    return marked;
}
