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
        var out: std.ArrayList([]const u8) = .empty;
        const a = c.allocator;
        const dir = p.dir(from);
        const name = spec.name;
        switch (language) {
            .zig => {
                if (std.mem.endsWith(u8, name, ".zig")) {
                    if (try c.candidate(dir, name, &.{""})) |v| try out.append(a, v);
                } else for (c.named_modules) |m| {
                    if (std.mem.eql(u8, name, m.name) and @import("rules.zig").matches(m.from, from)) {
                        if (try c.candidate("", m.path, &.{""})) |v| try out.append(a, v);
                        break;
                    }
                }
            },
            .c => {
                if (try c.candidate(dir, name, &.{""})) |v| try out.append(a, v) else {
                    for (c.include_roots) |root| if (try c.candidate(root, name, &.{""})) |v| {
                        try out.append(a, v);
                        break;
                    };
                }
            },
            .javascript => {
                if (!std.mem.startsWith(u8, name, "./") and !std.mem.startsWith(u8, name, "../")) return &.{};
                const suffixes = &.{ "", ".ts", ".tsx", ".js", ".jsx", ".mjs", ".mts", ".cjs", ".cts", "/index.ts", "/index.tsx", "/index.js", "/index.jsx", "/index.mjs", "/index.cjs" };
                if (try c.candidate(dir, name, suffixes)) |v| try out.append(a, v) else if (std.mem.endsWith(u8, name, ".js")) {
                    if (try c.candidate(dir, name[0 .. name.len - 3], &.{ ".ts", ".tsx" })) |v| try out.append(a, v);
                }
            },
            .python => {
                var dots: usize = 0;
                while (dots < name.len and name[dots] == '.') : (dots += 1) {}
                const rel = try std.mem.replaceOwned(u8, a, name[dots..], ".", "/");
                if (dots > 0) {
                    var root = dir;
                    var n: usize = 1;
                    while (n < dots) : (n += 1) {
                        if (root.len == 0) return &.{};
                        root = p.dir(root);
                    }
                    var boundary: []const u8 = "";
                    for (c.python_roots) |search| if (p.within(search, dir) and search.len > boundary.len) {
                        boundary = search;
                    };
                    if (!p.within(boundary, root) or std.mem.eql(u8, boundary, root)) return &.{};
                    try c.python(&out, root, rel);
                } else {
                    for (c.python_roots) |root| {
                        try c.python(&out, root, rel);
                        if (out.items.len > 0) break;
                    }
                }
            },
            .go => {
                var owner: ?GoModule = null;
                for (c.go_modules) |m| if (p.within(m.root, from) and (owner == null or m.root.len > owner.?.root.len)) {
                    owner = m;
                };
                const m = owner orelse return &.{};
                if (!p.within(m.name, name)) return &.{};
                const tail = if (name.len == m.name.len) "" else name[m.name.len + 1 ..];
                const joined = try std.fmt.allocPrint(a, "{s}/{s}", .{ m.root, tail });
                const key = try p.normalize(a, if (m.root.len == 0) joined[1..] else joined);
                // A nested module is its own compilation boundary.
                for (c.go_modules) |other| if (other.root.len > m.root.len and p.within(other.root, key)) return &.{};
                if (c.packages.get(key)) |files| try out.appendSlice(a, files.items);
            },
            .rust => {
                var root = dir;
                while (root.len > 0 and !std.mem.eql(u8, p.base(root), "src")) root = p.dir(root);
                const filename = p.base(from);
                var module_dir = dir;
                if (!std.mem.eql(u8, filename, "mod.rs") and !std.mem.eql(u8, filename, "lib.rs") and !std.mem.eql(u8, filename, "main.rs")) module_dir = from[0 .. from.len - 3];
                if (spec.form == .rust_mod) {
                    if (try c.candidate(module_dir, name, &.{ ".rs", "/mod.rs" })) |v| try out.append(a, v);
                } else {
                    var s = name;
                    var base_dir = module_dir;
                    if (std.mem.startsWith(u8, s, "crate::")) {
                        base_dir = root;
                        s = s[7..];
                    } else if (std.mem.startsWith(u8, s, "self::")) s = s[6..] else while (std.mem.startsWith(u8, s, "super::")) {
                        base_dir = p.dir(base_dir);
                        s = s[7..];
                    }
                    var rel: []const u8 = try std.mem.replaceOwned(u8, a, s, "::", "/");
                    while (rel.len > 0) {
                        if (try c.candidate(base_dir, rel, &.{ ".rs", "/mod.rs" })) |v| {
                            try out.append(a, v);
                            break;
                        }
                        rel = p.dir(rel);
                    }
                }
            },
        }
        return out.toOwnedSlice(a);
    }
    fn python(c: Context, out: *std.ArrayList([]const u8), root: []const u8, rel: []const u8) !void {
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
