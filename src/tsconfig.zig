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
fn join(a: std.mem.Allocator, root: []const u8, name: []const u8) !?[]const u8 {
    return @import("resolve_path.zig").join(a, root, name, "") catch |err| switch (err) {
        error.InvalidPath => null,
        else => return err,
    };
}
fn configName(name: []const u8) bool {
    return std.mem.eql(u8, name, "tsconfig.json") or std.mem.eql(u8, name, "jsconfig.json");
}
pub fn load(a: std.mem.Allocator, gpa: std.mem.Allocator, paths: []const []const u8, files: anytype, context: anytype, comptime read: anytype) ![]const Config {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    var entries: std.ArrayList(Entry) = .empty;
    var index: std.StringHashMapUnmanaged(usize) = .empty;
    for (paths) |file| if (configName(p.base(file))) {
        try index.put(a, file, entries.items.len);
        try entries.append(a, .{ .config = .{ .path = file } });
    };
    var i: usize = 0;
    while (i < entries.items.len) : (i += 1) {
        const file = entries.items[i].config.path;
        const s = scratch.allocator();
        defer _ = scratch.reset(.retain_capacity);
        const text = (try read(context, file, s)) orelse continue;
        const value = try @import("jsonc.zig").parse(a, s, text);
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
        var progress = false;
        for (entries.items) |*entry| {
            if (entry.done) continue;
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
            progress = true;
        }
        if (!progress) return error.ConfigCycle;
    }
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
