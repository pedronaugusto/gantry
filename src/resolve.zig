const std = @import("std");
const p = @import("path.zig");
const t = @import("types.zig");
pub const PythonInitializers = enum { ancestors, explicit, modulefinder };
pub const NamedModule = struct { name: []const u8, path: []const u8, from: []const u8 = "**" };
pub const GoModule = @import("go_config.zig").Module;
pub const Context = struct {
    allocator: std.mem.Allocator,
    files: *const std.StringHashMapUnmanaged(void),
    packages: *const std.StringHashMapUnmanaged(std.ArrayList([]const u8)),
    go_modules: []const GoModule,
    go_workspaces: []const @import("go_config.zig").Workspace = &.{},
    named_modules: []const NamedModule,
    include_roots: []const []const u8,
    python_roots: []const []const u8,
    python_initializers: PythonInitializers = .ancestors,
    python_reexports: *const std.StringHashMapUnmanaged([]const []const u8) = &.empty,
    ts_configs: []const @import("tsconfig.zig").Config = &.{},
    nim_configs: []const @import("nim_config.zig").Config = &.{},
    pub fn candidate(c: Context, root: []const u8, name: []const u8, suffixes: []const []const u8) !?[]const u8 {
        for (suffixes) |suffix| {
            const norm = @import("resolve_path.zig").join(c.allocator, root, name, suffix) catch |err| switch (err) {
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
            if (c.python_initializers == .explicit) return;
            var parent = p.dir(rel);
            while (parent.len > 0) {
                if (try c.candidate(root, parent, &.{"/__init__.py"})) |init| try out.append(c.allocator, init);
                parent = p.dir(parent);
            }
        }
    }
};
