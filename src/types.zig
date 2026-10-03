const std = @import("std");
pub const Language = enum { zig, c, javascript, python, go, rust, nim };
pub const Kind = enum { import, link, asset, @"test" };
pub const Edge = struct { from: []const u8, to: []const u8, kind: Kind = .import, count: usize = 1 };
pub const Form = enum { literal, python, rust_mod, rust_use };
/// Raw references borrow the source or the allocator passed to the lexer.
pub const Spec = struct { name: []const u8, offset: usize, form: Form = .literal, member: ?[]const u8 = null, kind: Kind = .import, scope: []const u8 = "", python_base: bool = false, star: bool = false };
pub const Reference = struct { from: []const u8, name: []const u8, offset: usize, member: ?[]const u8 = null, resolved: bool = false, kind: Kind = .import };
/// The lexical construct that recovery could not turn into a reference, or
/// a manifest construct it could not turn into a declaration.
pub const ImportExpression = enum {
    zig_import,
    c_include,
    javascript_import,
    javascript_require,
    python_importlib,
    python_import,
    rust_include,
    rust_path,
    /// An `import` or `from` operand that is not a module path or string.
    nim_import,
    /// An `include` operand that is not a module path or string.
    nim_include,
    /// A `.nimble` `requires` or `taskRequires` argument that is not a string literal.
    nimble_requires,
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
    /// Where the declaration says the dependency comes from, read from the
    /// key or form that gave `source` rather than guessed from its text.
    origin: Origin = .registry,

    pub const Origin = enum {
        /// No place of its own: a name the ecosystem's registry or module
        /// proxy resolves. A Go requirement's module path is a `remote`.
        registry,
        /// A folder on this machine: a ZON `.path`, a Cargo or Poetry
        /// `path`, an npm `file:`, `link:` or path, a PEP 508 `file:` URL.
        local,
        /// A repository or archive elsewhere: a ZON `.url`, a Cargo or
        /// Poetry `git` or `url`, an npm git, URL or `owner/repo`
        /// shorthand, a PEP 508 URL, a Go module path, a Nimble URL.
        remote,
        /// Another member of the same workspace: npm `workspace:`, Cargo
        /// `workspace = true`.
        workspace,
    };

    /// What the dependency is needed for, by its manifest's own groups.
    pub const Scope = enum {
        /// To run: npm `dependencies` and `peerDependencies`, Cargo
        /// `dependencies`, PEP 621 `project.dependencies`, Poetry's main
        /// table, Nimble `requires`, every ZON and Go requirement.
        runtime,
        /// To develop or test: npm `devDependencies`, Cargo
        /// `dev-dependencies`, PEP 735 `dependency-groups`, Poetry's
        /// `dev-dependencies` and named groups, Nimble `taskRequires`.
        development,
        /// Only when asked for: npm `optionalDependencies`, PEP 621
        /// `project.optional-dependencies` (extras), Nimble `feature` blocks.
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
        if (std.mem.endsWith(u8, manifest, ".nimble")) {
            if (std.mem.startsWith(u8, dep.group, "taskRequires.")) return .development;
            if (std.mem.startsWith(u8, dep.group, "feature.")) return .optional;
            return .runtime;
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

    /// The revision a remote source pins in its own text, as a slice of
    /// `source`: what follows `#` in a git URL (`git+https://host/x#v1`,
    /// `github:owner/x#main`), or what follows the path's `@` in a PEP 508
    /// VCS URL (`git+https://host/x.git@v1`). Empty when it names none, for
    /// every other origin, and for a revision a manifest keeps under a key
    /// of its own (Cargo's and Poetry's `rev`, `tag`, `branch`), which is
    /// not read. A Go requirement's version is its `requirement`. A Nimble
    /// package from the registry can pin one too (`name#head`), as a slice
    /// of its `requirement`.
    pub fn revision(dep: Dependency) []const u8 {
        const manifest = baseName(dep.manifest);
        if (std.mem.endsWith(u8, manifest, ".nimble") and dep.origin == .registry and std.mem.startsWith(u8, dep.requirement, "#")) return dep.requirement[1..];
        if (dep.origin != .remote) return "";
        if (std.mem.eql(u8, manifest, "go.mod")) return "";
        if (std.mem.eql(u8, manifest, "pyproject.toml")) return vcsRevision(dep.source);
        const hash = std.mem.lastIndexOfScalar(u8, dep.source, '#') orelse return "";
        return dep.source[hash + 1 ..];
    }

    /// `git+https://host/owner/x.git@v1#egg=x` → `v1`.
    fn vcsRevision(source: []const u8) []const u8 {
        const plus = std.mem.indexOfScalar(u8, source, '+') orelse return "";
        const scheme = std.mem.indexOf(u8, source, "://") orelse return "";
        if (plus > scheme) return "";
        const url = source[0 .. std.mem.indexOfScalar(u8, source, '#') orelse source.len];
        const path = std.mem.indexOfScalarPos(u8, url, scheme + 3, '/') orelse return "";
        const at = std.mem.lastIndexOfScalar(u8, url[path..], '@') orelse return "";
        return url[path + at + 1 ..];
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
