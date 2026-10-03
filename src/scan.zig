//! Caller-selected scanning and owned lexical and directory results.
const std = @import("std");
const t = @import("types.zig");
const resolver = @import("resolve.zig");
const recover = @import("recover.zig");
const Graph = @import("graph_store.zig");
const diagnostics = @import("scan_diagnostic.zig");
const manifests = @import("manifests.zig");
const path = @import("path.zig");
const languages = @import("languages.zig");
const api = @import("scan_options.zig");
const languageOf = api.languageOf;
const Options = api.Options;
const Language = t.Language;
const Kind = t.Kind;
const Edge = t.Edge;
const Reference = t.Reference;
const Dependency = t.Dependency;
const GoFile = api.GoFile;
const ImportStore = @import("import_store.zig");
const PathStore = @import("owned_slice.zig").Store([]const u8);
pub const Imports = @import("Imports.zig").Imports;
pub const Paths = PathStore.Owner;

pub fn imports(gpa: std.mem.Allocator, language: Language, source: []const u8) !Imports {
    const result = try ImportStore.create(gpa);
    errdefer result.deinit();
    const a = result.arena.allocator();
    result.recovery = try extract(a, language, try a.dupe(u8, source));
    return ImportStore.owner(Imports, result);
}
fn extract(a: std.mem.Allocator, language: Language, source: []const u8) !t.Recovery {
    return switch (language) {
        inline else => |lang| @field(languages, @tagName(lang)).recover(a, source),
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
pub fn scan(gpa: std.mem.Allocator, paths: []const []const u8, context: anytype, comptime read: anytype, options: Options) !@import("Graph.zig").Graph {
    return scanWithDiagnostic(gpa, paths, context, read, options, null);
}
/// Clears the caller's diagnostic on entry. On failure it owns the failed
/// path, phase, optional byte offset and original cause after scan cleanup.
/// A null diagnostic has the same behavior as `scan`. Reporting never changes
/// the returned error; if its path copy runs out of memory, the path is null.
pub fn scanWithDiagnostic(gpa: std.mem.Allocator, paths: []const []const u8, context: anytype, comptime read: anytype, options: Options, diagnostic: ?*diagnostics.ScanDiagnostic) !@import("Graph.zig").Graph {
    diagnostics.reset(diagnostic);
    var progress: diagnostics.Progress = .{ .diagnostic = diagnostic };
    const g = Graph.initTracked(gpa, paths, &progress) catch |cause| {
        progress.fail(cause);
        return cause;
    };
    errdefer g.deinit();
    const a = g.arena.allocator();
    // Resolution indexes live for this scan; only returned data lives in g.
    var workspace: std.heap.ArenaAllocator = .init(gpa);
    defer workspace.deinit();
    const w = workspace.allocator();
    const Reader = @import("scan_reader.zig").Reader(@TypeOf(context), read);
    var reader: Reader = .{ .context = context, .allocator = gpa, .progress = &progress };
    defer reader.deinit();
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    // Runs before any path-owning storage is destroyed.
    errdefer |cause| progress.fail(cause);
    const code_enabled = options.strict_imports or enabled(options, .import) or enabled(options, .@"test");
    const needs_cache = blk: {
        if (code_enabled) for (g.paths) |p| {
            const language = languageOf(p);
            if (language == .go or language == .rust or (language == .python and options.python_star_reexports)) break :blk true;
        };
        break :blk false;
    };
    const cached: []?t.Recovery = if (needs_cache) try w.alloc(?t.Recovery, g.paths.len) else &.{};
    @memset(cached, null);
    var go_files: std.ArrayList(GoFile) = .empty;
    var inactive: std.StringHashMapUnmanaged(void) = .empty;
    for (g.paths, 0..) |p, file_index| if (languageOf(p) == .go) {
        const s = scratch.allocator();
        if (try reader.readFile(p, s)) |text| {
            progress.at(.go_constraints, p);
            const lexer = @import("lexer.zig");
            const tokens = try lexer.lex(.go, s, text);
            var info = try @import("go_build.zig").parseTokens(s, p, text, options.go_target, tokens);
            info.package = try a.dupe(u8, info.package);
            if (info.constraint) |constraint| info.constraint = try a.dupe(u8, constraint);
            try go_files.append(a, info);
            if (!info.selected) try inactive.put(w, p, {});
            if (info.selected and code_enabled) {
                progress.at(.imports, p);
                const recovery = try @import("lang/go.zig").recoverTokens(s, text, try lexer.compact(s, tokens));
                cached[file_index] = try recovery.clone(w, a);
            }
        }
        _ = scratch.reset(.retain_capacity);
    };
    progress.at(.go_constraints, null);
    g.go_files = try go_files.toOwnedSlice(a);
    var packages: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty;
    for (g.paths) |p| if (languageOf(p) == .go and !inactive.contains(p)) {
        progress.at(.resolution, p);
        const entry = try packages.getOrPut(w, path.dir(p));
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(w, p);
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
            progress.at(.manifests, p);
            if (is_mod or is_work) {
                const parsed = try @import("go_config.zig").parse(w, path.dir(p), try w.dupe(u8, text));
                if (is_mod) if (parsed.name) |name| {
                    try modules.append(w, .{ .root = path.dir(p), .name = name, .requires = parsed.requires, .replacements = parsed.replacements });
                };
                if (is_work) try workspaces.append(w, .{ .root = path.dir(p), .uses = parsed.uses, .replacements = parsed.replacements });
            }
            if (options.manifests and manifests.supported(p)) for (try manifests.parse(s, p, text)) |dep| {
                try deps.append(a, .{ .manifest = p, .name = try a.dupe(u8, dep.name), .source = try a.dupe(u8, dep.source), .requirement = try a.dupe(u8, dep.requirement), .group = try a.dupe(u8, dep.group) });
            };
        }
        _ = scratch.reset(.retain_capacity);
    }
    const configs = try @import("tsconfig.zig").load(w, gpa, g.paths, &g.files, &reader, Reader.readFile, &progress);
    progress.at(.resolution, null);
    const index = try recover.names(w, g.paths);
    const base_ctx: resolver.Context = .{ .allocator = w, .files = &g.files, .packages = &packages, .go_modules = modules.items, .go_workspaces = workspaces.items, .named_modules = options.named_modules, .include_roots = options.include_roots, .python_roots = options.python_roots, .python_initializers = options.python_initializers, .ts_configs = configs };
    const test_files = try @import("code_kind.zig").rustFiles(w, gpa, g.paths, base_ctx, &reader, Reader.readFile, cached, a, &progress);
    const reexports = if (options.python_star_reexports) try @import("python_exports.zig").index(w, gpa, g.paths, base_ctx, &reader, Reader.readFile, cached, a, &progress) else std.StringHashMapUnmanaged([]const []const u8).empty;
    var edges: std.ArrayList(Edge) = .empty;
    var refs: std.ArrayList(Reference) = .empty;
    var unsupported: std.ArrayList(t.UnsupportedReference) = .empty;
    for (g.paths, 0..) |p, file_index| {
        if (inactive.contains(p)) continue;
        const language = languageOf(p);
        const code = code_enabled and language != null;
        const links = enabled(options, .link) and std.mem.endsWith(u8, p, ".md");
        const assets = enabled(options, .asset) and recover.assetText(p);
        if (!code and !links and !assets) continue;
        const s = scratch.allocator();
        const prior = if (cached.len > 0) cached[file_index] else null;
        const text = (if (prior != null) "" else try reader.readFile(p, s)) orelse {
            _ = scratch.reset(.retain_capacity);
            continue;
        };
        var ctx = base_ctx;
        ctx.allocator = s;
        ctx.python_reexports = &reexports;
        if (code) {
            var seen: std.StringHashMapUnmanaged(void) = .empty;
            progress.at(.imports, p);
            const recovery = prior orelse try extract(s, language.?, text);
            if (options.strict_imports and recovery.unsupported.len > 0) {
                progress.offset = recovery.unsupported[0].offset;
                return error.UnsupportedImport;
            }
            for (recovery.unsupported) |record| try unsupported.append(a, .{
                .from = p,
                .offset = record.offset,
                .expression = record.expression,
            });
            const specs = recovery.specs;
            for (specs) |spec| {
                progress.at(.resolution, p);
                const kind: Kind = if (spec.kind == .@"test" or test_files.contains(p) or @import("code_kind.zig").file(language.?, p)) .@"test" else .import;
                const targets = try ctx.targets(p, language.?, spec);
                try refs.append(a, .{ .from = p, .name = if (prior != null) spec.name else try a.dupe(u8, spec.name), .offset = spec.offset, .member = if (spec.member) |member| (if (prior != null) member else try a.dupe(u8, member)) else null, .resolved = targets.len > 0, .kind = kind });
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
        if (links) {
            progress.at(.links, p);
            for (try recover.links(s, text)) |spec| {
                if (try recover.linkTarget(ctx, &index, p, spec)) |target| if (!std.mem.eql(u8, target, p)) try edges.append(a, .{ .from = p, .to = g.files.getKey(target).?, .kind = .link });
            }
        }
        if (assets) {
            progress.at(.assets, p);
            for (try recover.assets(s, text)) |spec| {
                const target = (try ctx.candidate("", spec.name, &.{""})) orelse (try ctx.candidate(path.dir(p), spec.name, &.{""})) orelse continue;
                if (!std.mem.eql(u8, target, p)) try edges.append(a, .{ .from = p, .to = g.files.getKey(target).?, .kind = .asset });
            }
        }
        _ = scratch.reset(.retain_capacity);
    }
    progress.at(.graph, null);
    g.edges = try Graph.coalesce(try edges.toOwnedSlice(a));
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
    // Selected paths and each extractor are already in source order.
    g.unsupported = try unsupported.toOwnedSlice(a);
    g.references = try refs.toOwnedSlice(a);
    g.dependencies = try deps.toOwnedSlice(a);
    g.unread = try reader.unreadPaths(a, &g.files);
    return @import("graph_store.zig").owner(@import("Graph.zig").Graph, g);
}
pub fn walk(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, context: anytype, comptime keep: anytype) !Paths {
    const result = try PathStore.create(gpa);
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
    return PathStore.owner(result);
}
