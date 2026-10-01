//! gantry reads caller-selected files and records their dependencies.
//! Managed results own their allocator; slices belong to that result until
//! deinit. There is no global state, git, compiler invocation or thread.
const std = @import("std");
const t = @import("types.zig");
const resolver = @import("resolve.zig");
const recover = @import("recover.zig");
pub const Graph = @import("Graph.zig");
pub const Analysis = @import("Analysis.zig");
pub const Language = t.Language;
pub const Kind = t.Kind;
pub const Edge = t.Edge;
pub const Reference = t.Reference;
pub const Dependency = t.Dependency;
pub const Layer = t.Layer;
pub const Cycle = t.Cycle;
pub const Spec = t.Spec;
pub const PythonInitializers = resolver.PythonInitializers;
pub const GoTarget = @import("go_build.zig").Target;
pub const GoFile = @import("go_build.zig").File;
pub const NamedModule = resolver.NamedModule;
pub const rules = @import("rules.zig");
pub const manifests = @import("manifests.zig");
pub const path = @import("path.zig");
const languages = @import("languages.zig");
pub const Options = struct {
    kinds: []const Kind = &.{ .import, .@"test" },
    manifests: bool = true,
    named_modules: []const NamedModule = &.{},
    include_roots: []const []const u8 = &.{},
    python_roots: []const []const u8 = &.{""},
    go_target: ?GoTarget = null,
    python_initializers: PythonInitializers = .ancestors,
    python_star_reexports: bool = true,
};
pub fn languageOf(p: []const u8) ?Language {
    const ext = std.fs.path.extension(p);
    inline for (comptime std.meta.tags(Language)) |lang| {
        for (@field(languages, @tagName(lang)).extensions) |e| if (std.mem.eql(u8, ext, e)) return lang;
    }
    return null;
}
/// Raw lexical references, owning source bytes and every slice until deinit.
pub const Imports = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    items: []const Spec,
    pub fn deinit(self: *Imports) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
pub fn imports(gpa: std.mem.Allocator, language: Language, source: []const u8) !Imports {
    var result: Imports = .{ .allocator = gpa, .arena = .init(gpa), .items = &.{} };
    errdefer result.deinit();
    const a = result.arena.allocator();
    result.items = try extract(a, language, try a.dupe(u8, source));
    return result;
}
fn extract(a: std.mem.Allocator, language: Language, source: []const u8) ![]const Spec {
    return switch (language) {
        inline else => |lang| @field(languages, @tagName(lang)).imports(a, source),
    };
}
fn enabled(options: Options, kind: Kind) bool {
    for (options.kinds) |k| if (k == kind) return true;
    return false;
}
/// read(context, path, scratch_allocator) returns !?[]const u8. Bytes need
/// only survive this call's processing, until the next read. null records an
/// unread path; an error aborts without returning a partial graph. scratch
/// allocations are released after each file. Input paths and options are copied
/// where needed, so nothing returned borrows them or the file bytes.
pub fn scan(gpa: std.mem.Allocator, paths: []const []const u8, context: anytype, comptime read: anytype, options: Options) !Graph {
    var g = try Graph.init(gpa, paths);
    errdefer g.deinit();
    const a = g.arena.allocator();
    const Reader = @import("scan_reader.zig").Reader(@TypeOf(context), read);
    var reader: Reader = .{ .context = context, .allocator = gpa };
    defer reader.deinit();
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    var go_files: std.ArrayList(GoFile) = .empty;
    var inactive: std.StringHashMapUnmanaged(void) = .empty;
    for (g.paths) |p| if (languageOf(p) == .go) {
        const s = scratch.allocator();
        if (try reader.readFile(p, s)) |text| {
            var info = try @import("go_build.zig").parse(s, p, text, options.go_target);
            info.package = try a.dupe(u8, info.package);
            if (info.constraint) |constraint| info.constraint = try a.dupe(u8, constraint);
            try go_files.append(a, info);
            if (!info.selected) try inactive.put(a, p, {});
        }
        _ = scratch.reset(.retain_capacity);
    };
    g.go_files = try go_files.toOwnedSlice(a);
    var packages: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty;
    for (g.paths) |p| if (languageOf(p) == .go and !inactive.contains(p)) {
        const entry = try packages.getOrPut(a, path.dir(p));
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(a, p);
    };
    var modules: std.ArrayList(resolver.GoModule) = .empty;
    var workspaces: std.ArrayList(@import("go_config.zig").Workspace) = .empty;
    var deps: std.ArrayList(Dependency) = .empty;
    // Read manifests first: Go imports need the module identity even when
    // manifest dependencies have been disabled.
    for (g.paths) |p| {
        const is_mod = std.mem.eql(u8, path.base(p), "go.mod");
        const is_work = std.mem.eql(u8, path.base(p), "go.work");
        if (!is_work and !is_mod and (!manifests.supported(p) or !options.manifests)) continue;
        const s = scratch.allocator();
        if (try reader.readFile(p, s)) |text| {
            if (is_mod or is_work) {
                const parsed = try @import("go_config.zig").parse(a, path.dir(p), try a.dupe(u8, text));
                if (is_mod) if (parsed.name) |name| {
                    try modules.append(a, .{ .root = path.dir(p), .name = name, .requires = parsed.requires, .replacements = parsed.replacements });
                };
                if (is_work) try workspaces.append(a, .{ .root = path.dir(p), .uses = parsed.uses, .replacements = parsed.replacements });
            }
            if (options.manifests and manifests.supported(p)) for (try manifests.parse(s, p, text)) |dep| {
                try deps.append(a, .{ .manifest = p, .name = try a.dupe(u8, dep.name), .source = try a.dupe(u8, dep.source), .requirement = try a.dupe(u8, dep.requirement), .group = try a.dupe(u8, dep.group) });
            };
        }
        _ = scratch.reset(.retain_capacity);
    }
    const configs = try @import("tsconfig.zig").load(a, gpa, g.paths, &g.files, &reader, Reader.readFile);
    const index = try recover.names(a, g.paths);
    const base_ctx: resolver.Context = .{ .allocator = a, .files = &g.files, .packages = &packages, .go_modules = modules.items, .go_workspaces = workspaces.items, .named_modules = options.named_modules, .include_roots = options.include_roots, .python_roots = options.python_roots, .python_initializers = options.python_initializers, .ts_configs = configs };
    const test_files = try @import("code_kind.zig").rustFiles(a, gpa, g.paths, base_ctx, &reader, Reader.readFile);
    const reexports = if (options.python_star_reexports) try @import("python_exports.zig").index(a, gpa, g.paths, base_ctx, &reader, Reader.readFile) else std.StringHashMapUnmanaged([]const []const u8).empty;
    var edges: std.ArrayList(Edge) = .empty;
    var refs: std.ArrayList(Reference) = .empty;
    for (g.paths) |p| {
        if (inactive.contains(p)) continue;
        const language = languageOf(p);
        const code = (enabled(options, .import) or enabled(options, .@"test")) and language != null;
        const links = enabled(options, .link) and std.mem.endsWith(u8, p, ".md");
        const assets = enabled(options, .asset) and recover.assetText(p);
        if (!code and !links and !assets) continue;
        const s = scratch.allocator();
        const text = (try reader.readFile(p, s)) orelse {
            _ = scratch.reset(.retain_capacity);
            continue;
        };
        var ctx: resolver.Context = .{ .allocator = s, .files = &g.files, .packages = &packages, .go_modules = modules.items, .go_workspaces = workspaces.items, .named_modules = options.named_modules, .include_roots = options.include_roots, .python_roots = options.python_roots, .python_initializers = options.python_initializers, .ts_configs = configs };
        ctx.python_reexports = &reexports;
        if (code) {
            var seen: std.StringHashMapUnmanaged(void) = .empty;
            const specs = try extract(s, language.?, text);
            for (specs) |spec| {
                const kind: Kind = if (spec.kind == .@"test" or test_files.contains(p) or @import("code_kind.zig").file(language.?, p)) .@"test" else .import;
                const targets = try ctx.targets(p, language.?, spec);
                try refs.append(a, .{ .from = p, .name = try a.dupe(u8, spec.name), .offset = spec.offset, .member = if (spec.member) |member| try a.dupe(u8, member) else null, .resolved = targets.len > 0, .kind = kind });
                if (spec.member != null) continue;
                if (language == .python and options.python_initializers == .explicit and spec.python_base and !spec.star) {
                    var children: usize = 0;
                    var missing = false;
                    for (specs) |child| if (child.offset == spec.offset and !child.python_base) {
                        children += 1;
                        if ((try ctx.targets(p, .python, child)).len == 0) missing = true;
                    };
                    if (children > 0 and !missing) continue;
                }
                for (targets) |target| {
                    const edge_kind: Kind = if (kind == .@"test" or test_files.contains(target) or @import("code_kind.zig").file(language.?, target)) .@"test" else .import;
                    if (!enabled(options, edge_kind)) continue;
                    const key = try std.fmt.allocPrint(s, "{d}:{s}", .{ spec.offset, target });
                    const entry = try seen.getOrPut(s, key);
                    if (!entry.found_existing) try edges.append(a, .{ .from = p, .to = g.files.getKey(target).?, .kind = edge_kind });
                }
            }
        }
        if (links) for (try recover.links(s, text)) |spec| {
            if (try recover.linkTarget(ctx, &index, p, spec)) |target| if (!std.mem.eql(u8, target, p)) try edges.append(a, .{ .from = p, .to = g.files.getKey(target).?, .kind = .link });
        };
        if (assets) for (try recover.assets(s, text)) |spec| {
            const target = (try ctx.candidate("", spec.name, &.{""})) orelse (try ctx.candidate(path.dir(p), spec.name, &.{""})) orelse continue;
            if (!std.mem.eql(u8, target, p)) try edges.append(a, .{ .from = p, .to = g.files.getKey(target).?, .kind = .asset });
        };
        _ = scratch.reset(.retain_capacity);
    }
    g.edges = try Graph.coalesce(a, try edges.toOwnedSlice(a));
    std.mem.sort(Reference, refs.items, {}, struct {
        fn less(_: void, x: Reference, y: Reference) bool {
            const from = std.mem.order(u8, x.from, y.from);
            if (from != .eq) return from == .lt;
            if (x.offset != y.offset) return x.offset < y.offset;
            const name = std.mem.order(u8, x.name, y.name);
            if (name != .eq) return name == .lt;
            return std.mem.order(u8, x.member orelse "", y.member orelse "") == .lt;
        }
    }.less);
    std.mem.sort(Dependency, deps.items, {}, struct {
        fn less(_: void, x: Dependency, y: Dependency) bool {
            const manifest = std.mem.order(u8, x.manifest, y.manifest);
            if (manifest != .eq) return manifest == .lt;
            const group = std.mem.order(u8, x.group, y.group);
            if (group != .eq) return group == .lt;
            const name = std.mem.order(u8, x.name, y.name);
            if (name != .eq) return name == .lt;
            const requirement = std.mem.order(u8, x.requirement, y.requirement);
            if (requirement != .eq) return requirement == .lt;
            return std.mem.order(u8, x.source, y.source) == .lt;
        }
    }.less);
    g.references = try refs.toOwnedSlice(a);
    g.dependencies = try deps.toOwnedSlice(a);
    g.unread = try reader.unreadPaths(a);
    return g;
}
/// Reader over an already-open directory; directory ownership stays with caller.
/// The byte limit is caller policy. A missing selected file is an I/O error.
pub const DirReader = struct {
    io: std.Io,
    dir: std.Io.Dir,
    limit: std.Io.Limit = .unlimited,
    pub fn read(self: DirReader, p: []const u8, a: std.mem.Allocator) !?[]const u8 {
        return try self.dir.readFileAlloc(self.io, p, a, self.limit);
    }
};
/// Convenience listing. keep(context, slash_path, entry_kind) may prune a
/// directory; no ignore policy is imposed. Paths own their allocator.
pub const Paths = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    items: []const []const u8,
    pub fn deinit(self: *Paths) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
pub fn walk(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, context: anytype, comptime keep: anytype) !Paths {
    var result: Paths = .{ .allocator = gpa, .arena = .init(gpa), .items = &.{} };
    errdefer result.deinit();
    const a = result.arena.allocator();
    var list: std.ArrayList([]const u8) = .empty;
    var pending: std.ArrayList([]const u8) = .empty;
    try pending.append(a, "");
    while (pending.pop()) |prefix| {
        var child = try dir.openDir(io, if (prefix.len == 0) "." else prefix, .{ .iterate = true });
        defer child.close(io);
        var iter = child.iterate();
        while (try iter.next(io)) |entry| {
            const full = if (prefix.len == 0) try a.dupe(u8, entry.name) else try std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, entry.name });
            if (!keep(context, full, entry.kind)) continue;
            switch (entry.kind) {
                .directory => try pending.append(a, full),
                .file => try list.append(a, full),
                else => {},
            }
        }
    }
    std.mem.sort([]const u8, list.items, {}, t.stringsLess);
    result.items = try list.toOwnedSlice(a);
    return result;
}
test {
    _ = @import("tests.zig");
}
