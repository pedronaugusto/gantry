//! Selected repository configs only: JSONC, local extends and compilerOptions.
const path_module = @import("resolve/path.zig");
const diagnostic_module = @import("scan/diagnostic.zig");
const jsonc_module = @import("jsonc.zig");
const std = @import("std");
const p = @import("path.zig");
const Value = std.json.Value;
pub const Mapping = struct { pattern: []const u8, targets: []const []const u8 };
pub const Config = struct {
    path: []const u8,
    base_url: ?[]const u8 = null,
    mappings: ?[]const Mapping = null,
    paths_root: []const u8 = "",
};
/// An invalid config is done at once and gives nothing: no config of its
/// own, nothing to the configs that extend it.
const Entry = struct { config: Config, value: Value = .null, parents: []const []const u8 = &.{}, done: bool = false, invalid: bool = false };
fn field(v: Value, key: []const u8) Value {
    return if (v == .object) v.object.get(key) orelse .null else .null;
}
fn validate(value: Value) error{InvalidConfig}!void {
    if (value != .object) return error.InvalidConfig;
    if (value.object.get("extends")) |ext| switch (ext) {
        .string => {},
        .array => |parents| for (parents.items) |parent| {
            if (parent != .string) return error.InvalidConfig;
        },
        else => return error.InvalidConfig,
    };
    if (value.object.get("compilerOptions")) |opts| {
        if (opts != .object) return error.InvalidConfig;
        if (opts.object.get("baseUrl")) |base| {
            if (base != .string) return error.InvalidConfig;
        }
        if (opts.object.get("paths")) |paths| {
            if (paths != .object) return error.InvalidConfig;
        }
    }
}
fn join(arena: std.mem.Allocator, root: []const u8, name: []const u8) !?[]const u8 {
    return path_module.join(arena, root, name, "") catch |err| switch (err) {
        error.InvalidPath => null,
        else => |e| return e,
    };
}
fn configName(name: []const u8) bool {
    return std.mem.eql(u8, name, "tsconfig.json") or std.mem.eql(u8, name, "jsconfig.json");
}
pub fn load(arena: std.mem.Allocator, gpa: std.mem.Allocator, paths: []const []const u8, files: anytype, context: anytype, comptime read: anytype, progress: *diagnostic_module.Progress) (diagnostic_module.ReadError(read) || error{OutOfMemory})![]const Config {
    progress.at(.configs, null);
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    var entries: std.ArrayList(Entry) = .empty;
    var index: std.StringHashMapUnmanaged(usize) = .empty;
    for (paths) |file| if (configName(p.base(file))) {
        progress.at(.configs, file);
        try index.put(arena, file, entries.items.len);
        try entries.append(arena, .{ .config = .{ .path = file } });
    };
    var i: usize = 0;
    while (i < entries.items.len) : (i += 1) {
        const file = entries.items[i].config.path;
        const s = scratch.allocator();
        defer _ = scratch.reset(.retain_capacity);
        const text = (try read(context, s, file)) orelse continue;
        progress.at(.configs, file);
        const value = jsonc_module.parse(arena, s, text) catch |err| {
            try invalidate(&entries.items[i], progress, err);
            continue;
        };
        validate(value) catch |err| {
            try invalidate(&entries.items[i], progress, err);
            continue;
        };
        entries.items[i].value = value;
        const ext = field(value, "extends");
        var parents: std.ArrayList([]const u8) = .empty;
        const values: []const Value = if (ext == .array) ext.array.items else &.{ext};
        for (values) |v| {
            if (v != .string) continue;
            // Package-based extends would require an installed environment.
            if (!std.mem.startsWith(u8, v.string, ".")) continue;
            var parent = (try join(arena, p.dir(file), v.string)) orelse continue;
            if (!files.contains(parent)) parent = try arena.print("{s}.json", .{parent});
            if (!files.contains(parent)) continue;
            try parents.append(arena, parent);
            if (!index.contains(parent)) {
                try index.put(arena, parent, entries.items.len);
                try entries.append(arena, .{ .config = .{ .path = parent } });
            }
        }
        entries.items[i].parents = try parents.toOwnedSlice(arena);
    }
    var remaining = entries.items.len;
    for (entries.items) |entry| if (entry.done) {
        remaining -= 1;
    };
    while (remaining > 0) {
        var made_progress = false;
        for (entries.items) |*entry| {
            if (entry.done) continue;
            progress.at(.configs, entry.config.path);
            var ready = true;
            for (entry.parents) |parent| if (!entries.items[index.get(parent).?].done) {
                ready = false;
            };
            if (!ready) continue;
            var cfg: Config = .{ .path = entry.config.path };
            for (entry.parents) |parent| {
                const from = entries.items[index.get(parent).?];
                if (from.invalid) continue;
                const inherited = from.config;
                if (inherited.base_url) |base| cfg.base_url = base;
                if (inherited.mappings) |m| {
                    cfg.mappings = m;
                    cfg.paths_root = inherited.paths_root;
                }
            }
            const opts = field(entry.value, "compilerOptions");
            const base = field(opts, "baseUrl");
            if (base == .string) cfg.base_url = try join(arena, p.dir(cfg.path), base.string);
            remaining -= 1;
            made_progress = true;
            const paths_value = field(opts, "paths");
            if (paths_value == .object) {
                cfg.mappings = mappings(arena, paths_value) catch |err| {
                    try invalidate(entry, progress, err);
                    continue;
                };
                cfg.paths_root = p.dir(cfg.path);
            }
            entry.config = cfg;
            entry.done = true;
        }
        if (!made_progress) {
            // Following unfinished parents for at least the entry count lands
            // inside a cycle, rather than in a config merely depending on it.
            var cyclic: usize = for (entries.items, 0..) |entry, n| {
                if (!entry.done) break n;
            } else unreachable;
            for (0..entries.items.len) |_| {
                cyclic = for (entries.items[cyclic].parents) |parent| {
                    const n = index.get(parent).?;
                    if (!entries.items[n].done) break n;
                } else unreachable;
            }
            // The config the walk landed on gives nothing, which lets the
            // rest of its cycle resolve without it.
            progress.at(.configs, entries.items[cyclic].config.path);
            try invalidate(&entries.items[cyclic], progress, error.ConfigCycle);
            remaining -= 1;
        }
    }
    progress.at(.configs, null);
    var out: std.ArrayList(Config) = .empty;
    for (entries.items) |entry| if (!entry.invalid and configName(p.base(entry.config.path))) {
        try out.append(arena, entry.config);
    };
    return out.toOwnedSlice(arena);
}

fn invalidate(entry: *Entry, progress: *diagnostic_module.Progress, err: anytype) !void {
    try progress.tolerate(err);
    entry.invalid = true;
    entry.done = true;
}
fn mappings(arena: std.mem.Allocator, paths: Value) ![]const Mapping {
    var out: std.ArrayList(Mapping) = .empty;
    var it = paths.object.iterator();
    while (it.next()) |pair| {
        if (pair.value_ptr.* != .array) return error.InvalidConfig;
        const pattern = pair.key_ptr.*;
        if (std.mem.count(u8, pattern, "*") > 1) return error.InvalidConfig;
        var targets: std.ArrayList([]const u8) = .empty;
        for (pair.value_ptr.array.items) |target| {
            if (target != .string or std.mem.count(u8, target.string, "*") > 1) return error.InvalidConfig;
            try targets.append(arena, target.string);
        }
        try out.append(arena, .{ .pattern = pattern, .targets = try targets.toOwnedSlice(arena) });
    }
    return out.toOwnedSlice(arena);
}
pub fn nearest(configs: []const Config, from: []const u8) ?Config {
    var best: ?Config = null;
    for (configs) |cfg| {
        const dir = p.dir(cfg.path);
        if (!p.within(dir, from)) continue;
        if (best == null or dir.len > p.dir(best.?.path).len or (dir.len == p.dir(best.?.path).len and std.mem.eql(u8, p.base(cfg.path), "tsconfig.json"))) best = cfg;
    }
    return best;
}
