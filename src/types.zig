const std = @import("std");
pub const Language = enum { zig, c, javascript, python, go, rust, nim, java };
/// What an edge or reference is. A source import is `import`, `type_only`,
/// `dynamic` or `test`; a test file's import, or an import of a test file,
/// is `test` whatever its form.
pub const Kind = enum {
    /// A static import, include or `require`.
    import,
    /// A Markdown link.
    link,
    /// A path a text file names.
    asset,
    /// An import in a test file or in code only a test build compiles, or
    /// one a package import makes of a test file (Go, Java, a Rust `mod`).
    @"test",
    /// An import for types alone: a TypeScript `import type`, `export
    /// type`, braces whose every name is marked `type`, `typeof import("x")`
    /// or `import("x").T` in a type; a Python import under `if TYPE_CHECKING:`.
    type_only,
    /// A module loaded when the code runs: JavaScript `import("x")`, Python
    /// `importlib.import_module("x")` and `__import__("x")`.
    dynamic,
};
pub const Edge = struct { from: []const u8, to: []const u8, kind: Kind = .import, count: usize = 1 };
pub const Form = enum {
    literal,
    python,
    rust_mod,
    rust_use,
    java_static,
    /// A Rust path rooted at a crate's name rather than at `crate`,
    /// `self`, `super` or a module of this file: a `use` path, an
    /// `extern crate`, or the first segment of a path in code.
    rust_crate,
};
/// Raw references borrow the source or the allocator passed to the lexer.
/// `dead` as on `Reference`.
pub const Spec = struct { name: []const u8, offset: usize, form: Form = .literal, member: ?[]const u8 = null, kind: Kind = .import, scope: []const u8 = "", python_base: bool = false, star: bool = false, dead: bool = false };
pub const Reference = struct {
    from: []const u8,
    name: []const u8,
    offset: usize,
    member: ?[]const u8 = null,
    resolved: bool = false,
    kind: Kind = .import,
    /// In code no build analyses: a Zig container-level declaration that
    /// nothing reaches, neither a root nor a test.
    dead: bool = false,
};
/// An identifier or string literal in a source file that a token rule names.
pub const Token = struct {
    pub const Kind = enum { identifier, string };
    path: []const u8,
    kind: Token.Kind,
    /// The identifier, or the string literal's value after its escapes.
    text: []const u8,
    /// Byte offset of the token's first byte, or of the opening quote of a
    /// string or a Zig `@"name"`.
    offset: usize,
    /// One-based line and byte column of `offset`.
    line: usize,
    column: usize,
};
/// The lexical construct that recovery could not turn into a reference, or
/// a manifest construct it could not turn into a declaration.
pub const ImportExpression = enum {
    zig_import,
    c_include,
    javascript_import,
    javascript_require,
    /// An `importlib.import_module` call whose names are not literal.
    python_importlib,
    /// A `__import__` call whose name is not a literal.
    python_import,
    rust_include,
    rust_path,
    /// An `import` or `from` operand that is not a module path or string.
    nim_import,
    /// An `include` operand that is not a module path or string.
    nim_include,
    /// A `.nimble` `requires` or `taskRequires` argument that is not a string literal.
    nimble_requires,
    /// `Class.forName(`, which loads a class by a name known at run time.
    java_for_name,
    /// A `.loadClass(` call on a class loader.
    java_load_class,
    /// A `pom.xml` dependency naming a property its file does not define.
    maven_dependency,
    /// A Gradle `dependencies` statement that is not a literal declaration.
    gradle_dependency,
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
    /// The package a Java file declares, empty for none.
    package: []const u8 = "",

    /// Records and scopes belong to the workspace. Names and members belong to
    /// returned references, so copy them directly into graph storage once.
    pub fn clone(self: Recovery, a: std.mem.Allocator, strings: std.mem.Allocator) !Recovery {
        const specs = try a.dupe(Spec, self.specs);
        for (specs) |*spec| {
            spec.name = try strings.dupe(u8, spec.name);
            if (spec.member) |member| spec.member = try strings.dupe(u8, member);
            spec.scope = try a.dupe(u8, spec.scope);
        }
        return .{ .specs = specs, .unsupported = try a.dupe(UnsupportedReference, self.unsupported), .package = try a.dupe(u8, self.package) };
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
        /// `path`, an npm `file:`, `link:` or path, a PEP 508 `file:` URL,
        /// a Maven `system` dependency's `systemPath`.
        local,
        /// A repository or archive elsewhere: a ZON `.url`, a Cargo or
        /// Poetry `git` or `url`, an npm git, URL or `owner/repo`
        /// shorthand, a PEP 508 URL, a Go module path, a Nimble URL.
        remote,
        /// Another member of the same workspace: npm `workspace:`, Cargo
        /// `workspace = true`, a Gradle `project(":path")`.
        workspace,
    };

    /// What the dependency is needed for, by its manifest's own groups.
    pub const Scope = enum {
        /// To run: npm `dependencies` and `peerDependencies`, Cargo
        /// `dependencies`, PEP 621 `project.dependencies`, Poetry's main
        /// table, Nimble `requires`, Maven `compile`, `runtime` and
        /// `system` scopes, Gradle `implementation`, `api`, `runtimeOnly`
        /// and other configurations, every ZON and Go requirement.
        runtime,
        /// To develop or test: npm `devDependencies`, Cargo
        /// `dev-dependencies`, PEP 735 `dependency-groups`, Poetry's
        /// `dev-dependencies` and named groups, Nimble `taskRequires`,
        /// Maven `test` scope, Gradle test configurations (`testImplementation`,
        /// `androidTestImplementation`, `testFixturesApi`).
        development,
        /// Only when asked for: npm `optionalDependencies`, PEP 621
        /// `project.optional-dependencies` (extras), Nimble `feature` blocks,
        /// a Maven `<optional>true</optional>` dependency outside `test` scope.
        optional,
        /// To build: Cargo `build-dependencies`, Maven `provided` scope,
        /// Gradle `compileOnly`, annotation processors and `buildscript`
        /// `classpath`.
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
        if (std.mem.eql(u8, manifest, "pom.xml")) {
            // `test` stays development even when optional; otherwise optional wins.
            const maven = dep.group[0 .. std.mem.findScalar(u8, dep.group, ',') orelse dep.group.len];
            if (std.mem.eql(u8, maven, "test")) return .development;
            if (std.mem.endsWith(u8, dep.group, ",optional")) return .optional;
            if (std.mem.eql(u8, maven, "provided")) return .build;
            return .runtime;
        }
        if (std.mem.eql(u8, manifest, "build.gradle") or std.mem.eql(u8, manifest, "build.gradle.kts")) {
            const configuration = dep.group;
            if (std.mem.startsWith(u8, configuration, "test") or std.mem.find(u8, configuration, "Test") != null) return .development;
            for ([_][]const u8{ "compileOnly", "compileOnlyApi", "annotationProcessor", "kapt", "ksp", "classpath" }) |name| if (std.mem.eql(u8, configuration, name)) return .build;
            if (std.mem.endsWith(u8, configuration, "CompileOnly") or std.mem.endsWith(u8, configuration, "AnnotationProcessor")) return .build;
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
        const hash = std.mem.findScalarLast(u8, dep.source, '#') orelse return "";
        return dep.source[hash + 1 ..];
    }

    /// The package's own name without the namespace its ecosystem
    /// qualifies it with, as a slice of `name`: a Maven or Gradle
    /// `group:artifact` gives `artifact` and a Gradle `project(":libs:x")`
    /// gives `x`; a Go module path gives its last element, or the one
    /// before a major version suffix (`host/me/kit/v3` → `kit`); an npm
    /// `@scope/x` gives `x`. Every other name is already its own.
    pub fn shortName(dep: Dependency) []const u8 {
        const manifest = baseName(dep.manifest);
        const name = dep.name;
        if (std.mem.eql(u8, manifest, "pom.xml") or std.mem.eql(u8, manifest, "build.gradle") or std.mem.eql(u8, manifest, "build.gradle.kts")) {
            return name[if (std.mem.findScalarLast(u8, name, ':')) |colon| colon + 1 else 0..];
        }
        if (std.mem.eql(u8, manifest, "go.mod")) {
            const path = std.mem.trimEnd(u8, name, "/");
            const slash = std.mem.findScalarLast(u8, path, '/') orelse return path;
            const last = path[slash + 1 ..];
            if (!majorSuffix(last)) return last;
            const before = path[0..slash];
            return before[if (std.mem.findScalarLast(u8, before, '/')) |s| s + 1 else 0..];
        }
        if (std.mem.eql(u8, manifest, "package.json") and std.mem.startsWith(u8, name, "@")) {
            return name[if (std.mem.findScalar(u8, name, '/')) |slash| slash + 1 else 0..];
        }
        return name;
    }

    /// A Go major version element: `v2`, `v3`, … (`v0` and `v1` are never
    /// spelled in a module path).
    fn majorSuffix(element: []const u8) bool {
        if (element.len < 2 or element[0] != 'v' or element[1] == '0') return false;
        for (element[1..]) |c| if (!std.ascii.isDigit(c)) return false;
        return !std.mem.eql(u8, element, "v1");
    }

    /// `git+https://host/owner/x.git@v1#egg=x` → `v1`.
    fn vcsRevision(source: []const u8) []const u8 {
        const plus = std.mem.findScalar(u8, source, '+') orelse return "";
        const scheme = std.mem.find(u8, source, "://") orelse return "";
        if (plus > scheme) return "";
        const url = source[0 .. std.mem.findScalar(u8, source, '#') orelse source.len];
        const path = std.mem.findScalarPos(u8, url, scheme + 3, '/') orelse return "";
        const at = std.mem.findScalarLast(u8, url[path..], '@') orelse return "";
        return url[path + at + 1 ..];
    }

    fn baseName(manifest: []const u8) []const u8 {
        const slash = std.mem.lastIndexOfAny(u8, manifest, "/\\") orelse return manifest;
        return manifest[slash + 1 ..];
    }
};
pub const Layer = struct { path: []const u8, depth: usize };
/// The coupling of a file, or of a directory and everything under it: the
/// distinct file-to-file dependencies that cross its boundary, whatever
/// their kinds and counts.
pub const Coupling = struct {
    path: []const u8,
    /// The graph's nodes it holds: one for a file, and directories in an
    /// aggregate's analysis.
    files: usize = 1,
    /// Afferent coupling (Ca): dependencies on it from outside.
    fan_in: usize,
    /// Efferent coupling (Ce): its dependencies on what lies outside.
    fan_out: usize,
    /// Ce / (Ca + Ce), from 0 (depended on, depending on nothing outside)
    /// to 1 (depending, with no dependents); 0 with neither.
    pub fn instability(c: Coupling) f64 {
        const total = c.fan_in + c.fan_out;
        if (total == 0) return 0;
        return @as(f64, @floatFromInt(c.fan_out)) / @as(f64, @floatFromInt(total));
    }
};
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
