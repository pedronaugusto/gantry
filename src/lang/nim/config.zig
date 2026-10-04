//! Nim search paths from selected `nim.cfg`, `config.nims` and project
//! configs. Only literal paths are read; `$` substitutions and computed
//! NimScript values are not evaluated, and conditions are not either.
const std = @import("std");
const l = @import("../../lexer.zig");
const p = @import("../../path.zig");
/// The paths one config adds, joined to its folder, in the order it adds them.
/// A config applies to the files below its folder.
pub const Config = struct { dir: []const u8, paths: []const []const u8 };

/// `nim.cfg`, `config.nims`, and a project's `<name>.nim.cfg` or `<name>.nims`.
pub fn name(file: []const u8) bool {
    const base = p.base(file);
    return std.mem.eql(u8, base, "nim.cfg") or std.mem.eql(u8, base, "config.nims") or std.mem.endsWith(u8, base, ".nim.cfg") or std.mem.endsWith(u8, base, ".nims");
}

/// Configs ordered from the root down, so a nearer one comes later.
pub fn load(a: std.mem.Allocator, gpa: std.mem.Allocator, paths: []const []const u8, context: anytype, comptime read: anytype, progress: *@import("../../scan/diagnostic.zig").Progress) ![]const Config {
    var out: std.ArrayList(Config) = .empty;
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    for (paths) |file| if (name(file)) {
        const s = scratch.allocator();
        defer _ = scratch.reset(.retain_capacity);
        progress.at(.configs, file);
        const text = (try read(context, file, s)) orelse continue;
        progress.at(.configs, file);
        const values = if (std.mem.endsWith(u8, file, ".nims")) try script(s, text) else try cfg(s, text);
        var joined: std.ArrayList([]const u8) = .empty;
        for (values) |value| {
            if (value.len == 0 or std.mem.indexOfScalar(u8, value, '$') != null) continue;
            const full = @import("../../resolve/path.zig").join(a, p.dir(file), value, "") catch |err| switch (err) {
                error.InvalidPath => continue,
                else => return err,
            };
            try joined.append(a, full);
        }
        try out.append(a, .{ .dir = try a.dupe(u8, p.dir(file)), .paths = try joined.toOwnedSlice(a) });
    };
    progress.at(.configs, null);
    std.mem.sort(Config, out.items, {}, struct {
        fn less(_: void, x: Config, y: Config) bool {
            return x.dir.len < y.dir.len or (x.dir.len == y.dir.len and std.mem.order(u8, x.dir, y.dir) == .lt);
        }
    }.less);
    return out.toOwnedSlice(a);
}
/// Nim option names ignore case and underscores after the first letter.
fn pathKey(key: []const u8) bool {
    var trimmed = std.mem.trimStart(u8, key, "-");
    if (trimmed.len == 0) return false;
    if (std.mem.eql(u8, trimmed, "p")) return true;
    var buffer: [8]u8 = undefined;
    var n: usize = 0;
    for (trimmed) |c| if (c != '_') {
        if (n == buffer.len) return false;
        buffer[n] = std.ascii.toLower(c);
        n += 1;
    };
    trimmed = buffer[0..n];
    return std.mem.eql(u8, trimmed, "path");
}
/// `nim.cfg` lines: `--path:"x"`, `-p:x`, `path = "x"`, `path: "x"`.
fn cfg(a: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == '@') continue;
        const separator = std.mem.indexOfAny(u8, line, ":=") orelse continue;
        if (!pathKey(std.mem.trim(u8, line[0..separator], " \t"))) continue;
        var value = std.mem.trim(u8, line[separator + 1 ..], " \t");
        if (value.len > 0 and value[0] == '"') {
            const close = std.mem.indexOfScalarPos(u8, value, 1, '"') orelse continue;
            value = value[1..close];
        } else {
            value = value[0 .. std.mem.indexOfAny(u8, value, " \t#") orelse value.len];
        }
        try out.append(a, value);
    }
    return out.toOwnedSlice(a);
}
/// NimScript: `switch("path", "x")` and `--path:"x"`.
fn script(a: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const ts = try l.lexCompact(.nim, a, text, null);
    for (ts, 0..) |t, i| {
        if (t.is("switch") and i + 5 < ts.len and ts[i + 1].is("(") and ts[i + 2].kind == .string and ts[i + 3].is(",") and ts[i + 4].kind == .string and ts[i + 5].is(")")) {
            if (pathKey(ts[i + 2].text)) try out.append(a, ts[i + 4].text);
        }
        // `--path:"x"` is the `--` template applied to `path: "x"`.
        if (t.is("-") and i + 4 < ts.len and ts[i + 1].is("-") and ts[i + 1].offset == t.end and ts[i + 2].kind == .word and ts[i + 3].is(":") and pathKey(ts[i + 2].text)) {
            if (ts[i + 4].kind == .string and (i + 5 == ts.len or !ts[i + 5].is("&"))) try out.append(a, ts[i + 4].text);
        }
    }
    return out.toOwnedSlice(a);
}
