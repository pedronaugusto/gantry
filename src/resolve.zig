const std = @import("std");
const p = @import("path.zig");
const t = @import("types.zig");
pub const NamedModule = struct { name: []const u8, path: []const u8, from: []const u8 = "**" };
pub const GoModule = struct { root: []const u8, name: []const u8 };
pub const Context = struct {
    allocator: std.mem.Allocator,
    files: *const std.StringHashMapUnmanaged(void),
    packages: *const std.StringHashMapUnmanaged(std.ArrayList([]const u8)),
    go_modules: []const GoModule,
    named_modules: []const NamedModule,
    include_roots: []const []const u8,
    python_roots: []const []const u8,
    pub fn candidate(c: Context, root: []const u8, name: []const u8, suffixes: []const []const u8) !?[]const u8 {
        for (suffixes) |suffix| {
            const raw = try std.fmt.allocPrint(c.allocator, "{s}/{s}{s}", .{ root, name, suffix });
            // A leading slash is a join separator only for an empty root.
            const norm = p.normalize(c.allocator, if (root.len == 0) raw[1..] else raw) catch |err| switch (err) {
                error.InvalidPath => continue,
                else => return err,
            };
            if (c.files.contains(norm)) return norm;
        }
        return null;
    }
    pub fn targets(c: Context, from: []const u8, language: t.Language, spec: t.Spec) ![]const []const u8 {
        return switch (language) {
            inline else => |lang| @field(@import("languages.zig"), @tagName(lang)).resolve(c, from, spec),
        };
    }
    pub fn python(c: Context, out: *std.ArrayList([]const u8), root: []const u8, rel: []const u8) !void {
        // Only follow ancestors after the full module resolves: importing an
        // attribute from a package must not invent a module for that attribute.
        const target = try c.candidate(root, rel, if (rel.len == 0) &.{"__init__.py"} else &.{ ".py", "/__init__.py" });
        if (target) |v| {
            try out.append(c.allocator, v);
            var parent = p.dir(rel);
            while (parent.len > 0) {
                if (try c.candidate(root, parent, &.{"/__init__.py"})) |init| try out.append(c.allocator, init);
                parent = p.dir(parent);
            }
        }
    }
};
