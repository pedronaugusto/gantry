//! Dependency rules: imports joined to the declarations of the manifests
//! that govern them, per ecosystem; only an unresolved import can be
//! undeclared. An import names a package by its ecosystem's own spelling
//! rule; nothing is installed or looked up.
const options_module = @import("../scan/options.zig");
const std = @import("std");
const t = @import("../types.zig");
const p = @import("../path.zig");
const engine = @import("check.zig");
const builtins = @import("../builtins.zig");
const languageOf = options_module.languageOf;

pub const Ecosystem = enum {
    npm,
    python,
    cargo,
    go,
    zig,
    nim,
    java,

    fn of(language: t.Language) ?Ecosystem {
        return switch (language) {
            .javascript => .npm,
            .python => .python,
            .rust => .cargo,
            .go => .go,
            .zig => .zig,
            .nim => .nim,
            .java => .java,
            .c => null,
        };
    }
    /// The manifests of this ecosystem, by base name.
    fn manifest(e: Ecosystem, name: []const u8) bool {
        return switch (e) {
            .npm => std.mem.eql(u8, name, "package.json"),
            .python => std.mem.eql(u8, name, "pyproject.toml"),
            .cargo => std.mem.eql(u8, name, "Cargo.toml"),
            .go => std.mem.eql(u8, name, "go.mod"),
            .zig => std.mem.eql(u8, name, "build.zig.zon"),
            .nim => name.len > ".nimble".len and std.mem.endsWith(u8, name, ".nimble"),
            .java => std.mem.eql(u8, name, "pom.xml") or std.mem.eql(u8, name, "build.gradle") or std.mem.eql(u8, name, "build.gradle.kts"),
        };
    }
};

/// The package an import names, as a slice of its spelling, or
/// null when it names none: a relative or absolute path, a file, a module
/// the language's own distribution provides, or a spelling the ecosystem
/// gives no package (a URL, a `#` subpath import, a path alias).
pub fn packageOf(e: Ecosystem, name: []const u8) ?[]const u8 {
    if (name.len == 0) return null;
    switch (e) {
        .npm => {
            // npm names start with a letter, a digit or a scope's `@`.
            if (!(std.ascii.isAlphanumeric(name[0]) or name[0] == '@')) return null;
            if (std.mem.findScalar(u8, name, ':') != null) return null;
            const slash = std.mem.findScalar(u8, name, '/');
            if (name[0] == '@') {
                const first = slash orelse return null;
                if (first == 1 or first + 1 == name.len) return null;
                const second = std.mem.findScalarPos(u8, name, first + 1, '/') orelse name.len;
                return name[0..second];
            }
            const package = name[0 .. slash orelse name.len];
            return if (builtins.node.has(package)) null else package;
        },
        .python => {
            if (name[0] == '.') return null;
            const top = name[0 .. std.mem.findScalar(u8, name, '.') orelse name.len];
            return if (builtins.python.has(top)) null else top;
        },
        .cargo => {
            const path = if (std.mem.startsWith(u8, name, "::")) name[2..] else name;
            const root = path[0 .. std.mem.find(u8, path, "::") orelse path.len];
            for ([_][]const u8{ "std", "core", "alloc", "proc_macro", "test", "crate", "self", "super" }) |own| if (std.mem.eql(u8, root, own)) return null;
            return if (root.len == 0) null else root;
        },
        .go => {
            // The standard library's paths have no dot in their first element.
            const first = name[0 .. std.mem.findScalar(u8, name, '/') orelse name.len];
            return if (std.mem.findScalar(u8, first, '.') == null) null else name;
        },
        .zig => {
            if (std.mem.endsWith(u8, name, ".zig") or std.mem.endsWith(u8, name, ".zon")) return null;
            for ([_][]const u8{ "std", "builtin", "root" }) |own| if (std.mem.eql(u8, name, own)) return null;
            return name;
        },
        .nim => {
            if (name[0] == '.' or name[0] == '/' or std.mem.startsWith(u8, name, "std/") or std.mem.eql(u8, name, "system") or std.mem.startsWith(u8, name, "system/")) return null;
            const rest = if (std.mem.startsWith(u8, name, "pkg/")) name[4..] else name;
            const first = rest[0 .. std.mem.findScalar(u8, rest, '/') orelse rest.len];
            if (first.len == 0) return null;
            return if (first.len == rest.len and builtins.nim.has(first)) null else first;
        },
        .java => {
            // The package is the run of lower-case names before a type.
            var end: usize = 0;
            var parts = std.mem.splitScalar(u8, name, '.');
            while (parts.next()) |part| {
                if (part.len == 0 or !std.ascii.isLower(part[0])) break;
                end = if (end == 0) part.len else end + 1 + part.len;
            }
            const package = name[0..end];
            if (package.len == 0 or std.mem.startsWith(u8, package, "java.") or std.mem.startsWith(u8, package, "jdk.") or builtins.java.has(package)) return null;
            return package;
        },
    }
}

/// Whether `package`, as `packageOf` gives it or a rule's `names` spells
/// it, is what `dep` declares.
pub fn declares(e: Ecosystem, dep: t.Dependency, package: []const u8) bool {
    return switch (e) {
        .npm, .zig => std.mem.eql(u8, dep.name, package),
        // PEP 503: case and runs of `-`, `_` and `.` are not significant.
        .python => samePython(dep.name, package),
        // Cargo turns a package's `-` into the crate's `_`.
        .cargo => sameBytes(dep.name, package, "-", '_'),
        // A module path, or a package inside the module.
        .go => within(package, dep.name, '/'),
        .nim => std.ascii.eqlIgnoreCase(dep.name, package),
        // A Java package inside the declaration's group.
        .java => dep.origin != .workspace and within(package, dep.name[0 .. std.mem.findScalar(u8, dep.name, ':') orelse dep.name.len], '.'),
    };
}
/// A `names` entry's package against a declaration: its whole name, or
/// its name without namespace (a Maven artifact, a Go module's last element).
fn named(e: Ecosystem, dep: t.Dependency, package: []const u8) bool {
    if (std.mem.eql(u8, dep.name, package) or std.mem.eql(u8, dep.shortName(), package)) return true;
    return switch (e) {
        .python => samePython(dep.name, package),
        .cargo => sameBytes(dep.name, package, "-", '_'),
        .nim => std.ascii.eqlIgnoreCase(dep.name, package),
        else => false,
    };
}
fn within(inner: []const u8, outer: []const u8, separator: u8) bool {
    return outer.len > 0 and std.mem.startsWith(u8, inner, outer) and (inner.len == outer.len or inner[outer.len] == separator);
}
fn sameBytes(x: []const u8, y: []const u8, from: []const u8, to: u8) bool {
    if (x.len != y.len) return false;
    for (x, y) |c, d| {
        const c2 = if (std.mem.findScalar(u8, from, c) != null) to else c;
        const d2 = if (std.mem.findScalar(u8, from, d) != null) to else d;
        if (c2 != d2) return false;
    }
    return true;
}
fn samePython(x: []const u8, y: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        const a_end = i >= x.len;
        const b_end = j >= y.len;
        if (a_end or b_end) return a_end and b_end;
        const c = x[i];
        const d = y[j];
        const c_sep = c == '-' or c == '_' or c == '.';
        const d_sep = d == '-' or d == '_' or d == '.';
        if (c_sep != d_sep) return false;
        if (c_sep) {
            while (i < x.len and (x[i] == '-' or x[i] == '_' or x[i] == '.')) i += 1;
            while (j < y.len and (y[j] == '-' or y[j] == '_' or y[j] == '.')) j += 1;
            continue;
        }
        if (std.ascii.toLower(c) != std.ascii.toLower(d)) return false;
        i += 1;
        j += 1;
    }
}
fn ignored(rule: engine.DependencyRule, name: []const u8) bool {
    for (rule.ignore) |pattern| if (engine.matchesToken(pattern, name)) return true;
    return false;
}
/// What an import's package is called in its manifests: a `names`
/// entry's package, or the package itself.
fn spelled(e: Ecosystem, rule: engine.DependencyRule, package: []const u8) ?[]const u8 {
    for (rule.names) |entry| {
        const hit = switch (e) {
            .go => within(package, entry.import, '/'),
            .java => within(package, entry.import, '.'),
            else => std.mem.eql(u8, package, entry.import),
        };
        if (hit) return entry.package;
    }
    return null;
}

/// Ecosystem and directory used to group governing manifests.
pub const Key = struct { Ecosystem, []const u8 };

/// The manifests that govern files of one ecosystem in one directory.
const Manifests = struct { first: usize, end: usize };

/// Undeclared imports in reference order, then unused declarations in
/// declaration order. Findings borrow the graph and the rule.
pub fn check(arena: std.mem.Allocator, g: anytype, rule: engine.DependencyRule, out: *engine.Collector) std.mem.Allocator.Error!void {
    const paths = g.paths();
    const deps = g.dependencies();
    var unread: std.StringHashMapUnmanaged(void) = .empty;
    for (g.unread()) |path| try unread.put(arena, path, {});
    // Manifests by ecosystem and directory, each with its declarations:
    // `deps` is sorted by manifest, so a manifest's are one run.
    var governing: std.HashMapUnmanaged(Key, std.ArrayList([]const u8), struct {
        pub const Self = @This();
        pub fn hash(_: Self, k: Key) u64 {
            return std.hash.Wyhash.hash(@backingInt(k[0]), k[1]);
        }
        pub fn eql(_: Self, x: Key, y: Key) bool {
            return x[0] == y[0] and std.mem.eql(u8, x[1], y[1]);
        }
    }, std.hash_map.default_max_load_percentage) = .empty;
    for (paths) |path| {
        if (unread.contains(path)) continue;
        for (std.enums.values(Ecosystem)) |e| if (e.manifest(p.base(path))) {
            const entry = try governing.getOrPut(arena, .{ e, p.dir(path) });
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            try entry.value_ptr.append(arena, path);
        };
    }
    if (governing.count() == 0) return;
    var runs: std.StringHashMapUnmanaged(struct { usize, usize }) = .empty;
    var start: usize = 0;
    for (deps, 0..) |dep, i| if (i + 1 == deps.len or !std.mem.eql(u8, dep.manifest, deps[i + 1].manifest)) {
        try runs.put(arena, dep.manifest, .{ start, i + 1 });
        start = i + 1;
    };
    const used = try arena.alloc(bool, deps.len);
    @memset(used, false);
    // Manifests that govern a source file of theirs the rule covers.
    var active: std.StringHashMapUnmanaged(void) = .empty;
    var reported: std.StringHashMapUnmanaged(void) = .empty;
    const Lookup = struct {
        fn find(map: anytype, e: Ecosystem, file: []const u8) ?[]const []const u8 {
            var dir = p.dir(file);
            while (true) {
                if (map.get(.{ e, dir })) |found| return found.items;
                if (dir.len == 0) return null;
                dir = p.dir(dir);
            }
        }
    };
    for (paths) |path| if (engine.matches(rule.from, path)) {
        const language = languageOf(path) orelse continue;
        const e = Ecosystem.of(language) orelse continue;
        for (Lookup.find(governing, e, path) orelse continue) |manifest| try active.put(arena, manifest, {});
    };
    for (g.references()) |*ref| {
        // A resolved import still uses its declaration: a Go `replace` or
        // workspace member, a Zig path dependency under a named module.
        if (!engine.matches(rule.from, ref.from)) continue;
        const e = Ecosystem.of(languageOf(ref.from) orelse continue) orelse continue;
        const package = packageOf(e, ref.name) orelse continue;
        const manifests = Lookup.find(governing, e, ref.from) orelse continue;
        const alias = spelled(e, rule, package);
        var found = false;
        for (manifests) |manifest| {
            const run = runs.get(manifest) orelse continue;
            // Go: only the longest module path that holds the package.
            var longest: ?usize = null;
            for (run[0]..run[1]) |i| {
                const hit = if (alias) |name| named(e, deps[i], name) else declares(e, deps[i], package);
                if (!hit) continue;
                found = true;
                if (e != .go) {
                    used[i] = true;
                } else if (longest == null or deps[i].name.len > deps[longest.?].name.len) longest = i;
            }
            if (longest) |i| used[i] = true;
        }
        if (found or ref.resolved or !rule.undeclared or ignored(rule, package) or (alias != null and ignored(rule, alias.?))) continue;
        // Once per file and package: a `from` import spells several names.
        const key = try arena.print("{s}\x00{s}", .{ ref.from, package });
        if ((try reported.getOrPut(arena, key)).found_existing) continue;
        try out.items.append(out.gpa, .{ .rule = rule.name, .reason = .undeclared, .reference = ref, .package = package, .path = manifests[0] });
    }
    for (deps, used) |*dep, is_used| {
        if (is_used or !active.contains(dep.manifest)) continue;
        const scope = dep.scope();
        for (rule.unused) |wanted| {
            if (wanted == scope) break;
        } else continue;
        if (ignored(rule, dep.name) or ignored(rule, dep.shortName()) or quiet(dep.*)) continue;
        try out.items.append(out.gpa, .{ .rule = rule.name, .reason = .unused, .dependency = dep, .path = dep.manifest });
    }
}
/// Declarations no import can name: a Go module only other modules
/// import (`// indirect`), Nimble's `nim` (the compiler), and a Gradle
/// project whose packages its name does not tell.
fn quiet(dep: t.Dependency) bool {
    const manifest = p.base(dep.manifest);
    if (std.mem.eql(u8, manifest, "go.mod")) return std.mem.eql(u8, dep.group, "indirect");
    if (std.mem.endsWith(u8, manifest, ".nimble")) return std.ascii.eqlIgnoreCase(dep.name, "nim");
    return dep.origin == .workspace and (std.mem.eql(u8, manifest, "build.gradle") or std.mem.eql(u8, manifest, "build.gradle.kts") or std.mem.eql(u8, manifest, "pom.xml"));
}
