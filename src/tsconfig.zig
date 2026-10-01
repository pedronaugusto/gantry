//! Selected repository configs only: JSONC, local extends and compilerOptions.
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
const Entry = struct { config: Config, value: Value = .null, parents: []const []const u8 = &.{}, done: bool = false };
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
fn join(a: std.mem.Allocator, root: []const u8, name: []const u8) !?[]const u8 {
    return @import("resolve_path.zig").join(a, root, name, "") catch |err| switch (err) {
        error.InvalidPath => null,
        else => return err,
    };
}
fn configName(name: []const u8) bool {
    return std.mem.eql(u8, name, "tsconfig.json") or std.mem.eql(u8, name, "jsconfig.json");
}
pub fn load(a: std.mem.Allocator, gpa: std.mem.Allocator, paths: []const []const u8, files: anytype, context: anytype, comptime read: anytype, progress: *@import("scan_diagnostic.zig").Progress) ![]const Config {
    progress.at(.configs, null);
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    var entries: std.ArrayList(Entry) = .empty;
    var index: std.StringHashMapUnmanaged(usize) = .empty;
    for (paths) |file| if (configName(p.base(file))) {
        progress.at(.configs, file);
        try index.put(a, file, entries.items.len);
        try entries.append(a, .{ .config = .{ .path = file } });
    };
    var i: usize = 0;
    while (i < entries.items.len) : (i += 1) {
        const file = entries.items[i].config.path;
        const s = scratch.allocator();
        defer _ = scratch.reset(.retain_capacity);
        const text = (try read(context, file, s)) orelse continue;
        progress.at(.configs, file);
        const value = try @import("jsonc.zig").parse(a, s, text);
        try validate(value);
        entries.items[i].value = value;
        const ext = field(value, "extends");
        var parents: std.ArrayList([]const u8) = .empty;
        const values: []const Value = if (ext == .array) ext.array.items else &.{ext};
        for (values) |v| {
            if (v != .string) continue;
            // Package-based extends would require an installed environment.
            if (!std.mem.startsWith(u8, v.string, ".")) continue;
            var parent = (try join(a, p.dir(file), v.string)) orelse continue;
            if (!files.contains(parent)) parent = try std.fmt.allocPrint(a, "{s}.json", .{parent});
            if (!files.contains(parent)) continue;
            try parents.append(a, parent);
            if (!index.contains(parent)) {
                try index.put(a, parent, entries.items.len);
                try entries.append(a, .{ .config = .{ .path = parent } });
            }
        }
        entries.items[i].parents = try parents.toOwnedSlice(a);
    }
    var remaining = entries.items.len;
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
                const inherited = entries.items[index.get(parent).?].config;
                if (inherited.base_url) |base| cfg.base_url = base;
                if (inherited.mappings) |m| {
                    cfg.mappings = m;
                    cfg.paths_root = inherited.paths_root;
                }
            }
            const opts = field(entry.value, "compilerOptions");
            const base = field(opts, "baseUrl");
            if (base == .string) cfg.base_url = try join(a, p.dir(cfg.path), base.string);
            const paths_value = field(opts, "paths");
            if (paths_value == .object) {
                var mappings: std.ArrayList(Mapping) = .empty;
                var it = paths_value.object.iterator();
                while (it.next()) |pair| {
                    if (pair.value_ptr.* != .array) return error.InvalidConfig;
                    const pattern = pair.key_ptr.*;
                    if (std.mem.count(u8, pattern, "*") > 1) return error.InvalidConfig;
                    var targets: std.ArrayList([]const u8) = .empty;
                    for (pair.value_ptr.array.items) |target| {
                        if (target != .string or std.mem.count(u8, target.string, "*") > 1) return error.InvalidConfig;
                        try targets.append(a, target.string);
                    }
                    try mappings.append(a, .{ .pattern = pattern, .targets = try targets.toOwnedSlice(a) });
                }
                cfg.mappings = try mappings.toOwnedSlice(a);
                cfg.paths_root = p.dir(cfg.path);
            }
            entry.config = cfg;
            entry.done = true;
            remaining -= 1;
            made_progress = true;
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
            progress.at(.configs, entries.items[cyclic].config.path);
            return error.ConfigCycle;
        }
    }
    progress.at(.configs, null);
    var out: std.ArrayList(Config) = .empty;
    for (entries.items) |entry| if (configName(p.base(entry.config.path))) {
        try out.append(a, entry.config);
    };
    return out.toOwnedSlice(a);
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
