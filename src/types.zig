const std = @import("std");
pub const Language = enum { zig, c, javascript, python, go, rust };
pub const Kind = enum { import, link, asset, @"test" };
pub const Edge = struct { from: []const u8, to: []const u8, kind: Kind = .import, count: usize = 1 };
pub const Form = enum { literal, python, rust_mod, rust_use };
/// Raw references borrow the source or the allocator passed to the lexer.
pub const Spec = struct { name: []const u8, offset: usize, form: Form = .literal, member: ?[]const u8 = null, kind: Kind = .import, scope: []const u8 = "", python_base: bool = false, star: bool = false };
pub const Reference = struct { from: []const u8, name: []const u8, offset: usize, member: ?[]const u8 = null, resolved: bool = false, kind: Kind = .import };
/// The lexical construct that recovery could not turn into a reference.
pub const ImportExpression = enum {
    zig_import,
    c_include,
    javascript_import,
    javascript_require,
    python_importlib,
    python_import,
    rust_include,
    rust_path,
};
/// Owned by Imports or Graph, with a byte offset at the construct's start.
pub const UnsupportedReference = struct {
    /// Null for anonymous source bytes passed to `imports`.
    from: ?[]const u8 = null,
    offset: usize,
    expression: ImportExpression,
};
/// Internal extraction result; all slices borrow source or extraction storage.
pub const Recovery = struct {
    specs: []const Spec = &.{},
    unsupported: []const UnsupportedReference = &.{},

    /// Records and scopes belong to the workspace. Names and members belong to
    /// returned references, so copy them directly into graph storage once.
    pub fn clone(self: Recovery, a: std.mem.Allocator, strings: std.mem.Allocator) !Recovery {
        const specs = try a.dupe(Spec, self.specs);
        for (specs) |*spec| {
            spec.name = try strings.dupe(u8, spec.name);
            if (spec.member) |member| spec.member = try strings.dupe(u8, member);
            spec.scope = try a.dupe(u8, spec.scope);
        }
        return .{ .specs = specs, .unsupported = try a.dupe(UnsupportedReference, self.unsupported) };
    }
};
/// One declared dependency, as its manifest spells it.
pub const Dependency = struct {
    manifest: []const u8,
    name: []const u8,
    requirement: []const u8 = "",
    source: []const u8 = "",
    group: []const u8 = "dependencies",

    /// What the dependency is needed for, by its manifest's own groups.
    pub const Scope = enum {
        /// To run: npm `dependencies` and `peerDependencies`, Cargo
        /// `dependencies`, PEP 621 `project.dependencies`, Poetry's main
        /// table, every ZON and Go requirement.
        runtime,
        /// To develop or test: npm `devDependencies`, Cargo
        /// `dev-dependencies`, PEP 735 `dependency-groups`, Poetry's
        /// `dev-dependencies` and named groups.
        development,
        /// Only when asked for: npm `optionalDependencies`, PEP 621
        /// `project.optional-dependencies` (extras).
        optional,
        /// To build: Cargo `build-dependencies`.
        build,
    };

    /// The scope its group puts it in. A Cargo target table
    /// (`target.'cfg(unix)'.dev-dependencies`) is the scope of its table.
    pub fn scope(dep: Dependency) Scope {
        const manifest = baseName(dep.manifest);
        if (std.mem.eql(u8, manifest, "package.json")) {
            if (std.mem.eql(u8, dep.group, "devDependencies")) return .development;
            if (std.mem.eql(u8, dep.group, "optionalDependencies")) return .optional;
            return .runtime;
        }
        if (std.mem.eql(u8, manifest, "pyproject.toml")) {
            if (std.mem.eql(u8, dep.group, "project.dependencies") or std.mem.eql(u8, dep.group, "tool.poetry.dependencies")) return .runtime;
            if (std.mem.startsWith(u8, dep.group, "project.optional-dependencies.")) return .optional;
            return .development;
        }
        if (std.mem.eql(u8, manifest, "Cargo.toml")) {
            var parts = std.mem.splitScalar(u8, dep.group, '.');
            while (parts.next()) |part| {
                if (std.mem.eql(u8, part, "dependencies")) return .runtime;
                if (std.mem.eql(u8, part, "dev-dependencies")) return .development;
                if (std.mem.eql(u8, part, "build-dependencies")) return .build;
            }
        }
        return .runtime;
    }

    fn baseName(manifest: []const u8) []const u8 {
        const slash = std.mem.lastIndexOfAny(u8, manifest, "/\\") orelse return manifest;
        return manifest[slash + 1 ..];
    }
};
pub const Layer = struct { path: []const u8, depth: usize };
pub const Cycle = struct { members: []const []const u8, path: []const []const u8 };
pub fn stringsLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}
pub fn edgesLess(_: void, a: Edge, b: Edge) bool {
    const from = std.mem.order(u8, a.from, b.from);
    if (from != .eq) return from == .lt;
    const to = std.mem.order(u8, a.to, b.to);
    if (to != .eq) return to == .lt;
    return @intFromEnum(a.kind) < @intFromEnum(b.kind);
}
