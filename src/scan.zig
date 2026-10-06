//! Caller-selected scanning and owned lexical and directory results.
const owned_slice_module = @import("owned_slice.zig");
const tokens_module = @import("tokens.zig");
const imports_module = @import("imports.zig");
const graph_module = @import("graph.zig");
const reader_module = @import("scan/reader.zig");
const check_module = @import("rules/check.zig");
const build_module = @import("lang/go/build.zig");
const go_module = @import("lang/go.zig");
const config_module = @import("lang/go/config.zig");
const tsconfig_module = @import("tsconfig.zig");
const config_module_ = @import("lang/nim/config.zig");
const code_kind_module = @import("code_kind.zig");
const packages_module = @import("lang/java/packages.zig");
const exports_module = @import("lang/python/exports.zig");
const std = @import("std");
const t = @import("types.zig");
const resolver = @import("resolve.zig");
const recover = @import("recover.zig");
const Graph = @import("graph/Storage.zig");
const diagnostics = @import("scan/diagnostic.zig");
const manifests = @import("manifests.zig");
const path = @import("path.zig");
const languages = @import("lang.zig");
const api = @import("scan/options.zig");
const languageOf = api.languageOf;
const Options = api.Options;
const Language = t.Language;
const Kind = t.Kind;
const Reference = t.Reference;
const Dependency = t.Dependency;
const GoFile = api.GoFile;
const ImportStore = @import("imports/State.zig");
const PathStore = owned_slice_module.Store([]const u8);
const Recorder = tokens_module.Recorder;
pub const Imports = imports_module.Imports;
pub const Paths = PathStore.Owner;

/// Scratch kept between files. A larger file's tokens go back to the
/// allocator rather than staying resident for the rest of the scan.
const scratch_kept = 1 << 20;

/// `InvalidEscape` or `InvalidLiteral` for a string literal recovery cannot decode.
pub fn imports(gpa: std.mem.Allocator, language: Language, source: []const u8) error{ InvalidEscape, InvalidLiteral, OutOfMemory }!Imports {
    const result = try ImportStore.create(gpa);
    errdefer result.deinit();
    const a = result.arena.allocator();
    result.recovery = try extract(a, language, try a.dupe(u8, source), null, 0, "");
    return ImportStore.owner(Imports, result);
}
/// Recovery, handing the token stream to the token rules on the way when
/// `recorder` still wants this file.
fn extract(a: std.mem.Allocator, language: Language, source: []const u8, recorder: ?*Recorder, index: usize, file: []const u8) !t.Recovery {
    return switch (language) {
        inline else => |lang| {
            const module = @field(languages, @tagName(lang));
            const seen = if (recorder) |r| r.observer(a, index, file, lang, source) else null;
            return module.recoverTokens(a, source, try module.lex(a, source, seen));
        },
    };
}
/// The reference kinds `scan` reads from `file`, by its name alone:
/// `import` and `test` from source in a supported language (`languageOf`),
/// and `type_only` and `dynamic` too from JavaScript, TypeScript and Python, `link`
/// from Markdown, `asset` from text that can name other files. Which of
/// them a scan collects is still `Options.kinds`.
pub fn kindsOf(file: []const u8) std.EnumSet(Kind) {
    var kinds: std.EnumSet(Kind) = .empty;
    if (languageOf(file)) |language| {
        kinds.insert(.import);
        kinds.insert(.@"test");
        if (language == .javascript or language == .python) {
            kinds.insert(.type_only);
            kinds.insert(.dynamic);
        }
    }
    if (std.mem.endsWith(u8, file, ".md")) kinds.insert(.link);
    if (recover.assetText(file)) kinds.insert(.asset);
    return kinds;
}
fn enabled(options: Options, kind: Kind) bool {
    for (options.kinds) |k| if (k == kind) return true;
    return false;
}
/// read(scratch_allocator, context, path) returns !?[]const u8. Bytes need
/// only survive this call's processing, until the next read. null records an
/// unread path; a reader error or a `ScanError` aborts without returning a
/// partial graph, and a file's own `FileError` is a record instead. scratch
/// allocations are released after each file. Input paths and options are copied
/// where needed, so nothing returned borrows them or the file bytes.
pub fn scan(gpa: std.mem.Allocator, paths: []const []const u8, context: anytype, comptime read: anytype, options: Options) (diagnostics.ScanError || diagnostics.ReadError(read))!graph_module.Graph {
    return scanWithDiagnostic(gpa, paths, context, read, options, null);
}
/// Clears the caller's diagnostic on entry. On failure it owns the failed
/// path, phase, optional byte offset and original cause after scan cleanup.
/// A null diagnostic has the same behavior as `scan`. Reporting never changes
/// the returned error; if its path copy runs out of memory, the path is null.
pub fn scanWithDiagnostic(gpa: std.mem.Allocator, paths: []const []const u8, context: anytype, comptime read: anytype, options: Options, diagnostic: ?*diagnostics.ScanDiagnostic) (diagnostics.ScanError || diagnostics.ReadError(read))!graph_module.Graph {
    diagnostics.reset(diagnostic);
    var progress: diagnostics.Progress = .{ .diagnostic = diagnostic };
    const Returned = diagnostics.ScanError || diagnostics.ReadError(read);
    return scanGraph(gpa, paths, context, read, options, &progress) catch |err| {
        // A file's own errors are recorded and never escape; everything
        // else that can is in the declared set, which this checks.
        comptime {
            @setEvalBranchQuota(100_000);
            const Inner = @typeInfo(@typeInfo(@TypeOf(scanGraph(gpa, paths, context, read, options, &progress))).error_union.error_set).error_set.error_names.?;
            for (Inner) |name| if (!has(Returned, name) and !has(diagnostics.FileError, name)) @compileError("scan can return error." ++ name);
        }
        return @errorCast(err);
    };
}
fn has(comptime Set: type, comptime name: []const u8) bool {
    const names = @typeInfo(Set).error_set.error_names orelse return true;
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}
fn scanGraph(gpa: std.mem.Allocator, paths: []const []const u8, context: anytype, comptime read: anytype, options: Options, progress: *diagnostics.Progress) !graph_module.Graph {
    const g = Graph.initTracked(gpa, paths, progress) catch |cause| {
        progress.fail(cause);
        return cause;
    };
    errdefer g.deinit();
    progress.records = g.arena.allocator();
    // Resolution indexes live for this scan; only returned data lives in g.
    var workspace: std.heap.ArenaAllocator = .init(gpa);
    defer workspace.deinit();
    var reader: reader_module.Reader(@TypeOf(context), read) = .{ .context = context, .allocator = gpa, .progress = progress };
    defer reader.deinit();
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    return fill(gpa, g, workspace.allocator(), &reader, &scratch, options, progress) catch |cause| {
        // The current path may be any of the storage above; it is
        // copied before that is released.
        progress.fail(cause);
        return cause;
    };
}
/// The scan proper, into `g`. Everything it allocates lives in `g`,
/// in the workspace `w` or in `scratch`, all owned by `scanGraph`.
fn fill(gpa: std.mem.Allocator, g: *Graph, w: std.mem.Allocator, reader: anytype, scratch: *std.heap.ArenaAllocator, options: Options, progress: *diagnostics.Progress) !graph_module.Graph {
    const Reader = @TypeOf(reader.*);
    const a = g.arena.allocator();
    const code_enabled = options.strict_imports or enabled(options, .import) or enabled(options, .type_only) or enabled(options, .dynamic) or enabled(options, .@"test");
    const needs_cache = blk: {
        if (code_enabled) for (g.paths) |p| {
            const language = languageOf(p);
            if (language == .go or language == .rust or language == .java or (language == .python and options.python_star_reexports)) break :blk true;
        };
        break :blk false;
    };
    var recorder: Recorder = try .init(w, a, options.tokens, g.paths.len);
    if (recorder.active()) {
        var scanned: std.ArrayList(Graph.ScannedToken) = .empty;
        for (options.tokens) |rule| for (rule.tokens) |token| try scanned.append(a, .{ .kind = rule.kind, .text = try a.dupe(u8, token) });
        g.scanned_tokens = scanned.items;
    }
    const cached: []?t.Recovery = if (needs_cache) try w.alloc(?t.Recovery, g.paths.len) else &.{};
    @memset(cached, null);
    var go_files: std.ArrayList(GoFile) = .empty;
    var inactive: std.StringHashMapUnmanaged(void) = .empty;
    for (g.paths, 0..) |p, file_index| if (languageOf(p) == .go) {
        const s = scratch.allocator();
        defer _ = scratch.reset(.{ .retain_with_limit = scratch_kept });
        const text = (try Reader.readFile(s, reader, p)) orelse continue;
        progress.at(.go_constraints, p);
        const tokens = try recorder.lex(languages.go, s, file_index, p, .go, text);
        var info = build_module.parseTokens(s, p, text, options.go_target, tokens) catch |err| {
            // Go leaves a file whose constraint it cannot read out of its package.
            try progress.tolerate(err);
            try inactive.put(w, p, {});
            continue;
        };
        info.package = try a.dupe(u8, info.package);
        if (info.constraint) |constraint| info.constraint = try a.dupe(u8, constraint);
        try go_files.append(a, info);
        if (!info.selected) try inactive.put(w, p, {});
        if (info.selected and code_enabled) {
            progress.at(.imports, p);
            const recovery = go_module.recoverTokens(s, text, tokens) catch |err| empty: {
                try progress.tolerate(err);
                break :empty t.Recovery{};
            };
            cached[file_index] = try recovery.clone(w, a);
        }
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
    var workspaces: std.ArrayList(config_module.Workspace) = .empty;
    var deps: std.ArrayList(Dependency) = .empty;
    var unsupported: std.ArrayList(t.UnsupportedReference) = .empty;
    // Read manifests first: Go imports need the module identity even when
    // manifest dependencies have been disabled.
    try readManifests(w, a, g, options, reader, scratch, progress, &modules, &workspaces, &deps, &unsupported);
    const configs = try tsconfig_module.load(w, gpa, g.paths, &g.files, reader, Reader.readFile, progress);
    const nim_configs = try config_module_.load(w, gpa, g.paths, reader, Reader.readFile, progress);
    progress.at(.resolution, null);
    const index = try recover.names(w, g.paths);
    const base_ctx: resolver.Context = .{ .allocator = w, .files = &g.files, .packages = &packages, .go_modules = modules.items, .go_workspaces = workspaces.items, .named_modules = options.named_modules, .include_roots = options.include_roots, .python_roots = options.python_roots, .python_initializers = options.python_initializers, .ts_configs = configs, .nim_configs = nim_configs };
    const test_files = try code_kind_module.rustFiles(w, gpa, a, g.paths, base_ctx, reader, Reader.readFile, cached, progress, &recorder);
    const java_packages = if (code_enabled) try packages_module.index(w, gpa, a, g.paths, reader, Reader.readFile, cached, progress, &recorder) else std.StringHashMapUnmanaged(std.ArrayList([]const u8)).empty;
    const reexports = if (options.python_star_reexports) try exports_module.index(w, gpa, a, g.paths, base_ctx, reader, Reader.readFile, cached, progress, &recorder) else std.StringHashMapUnmanaged([]const []const u8).empty;
    // Edges wait as path positions outside graph storage: a quarter of an
    // `Edge`, and their outgrown buffers go back to the allocator.
    const position = try Graph.positions(w, g.paths);
    var edges: std.ArrayList(Graph.Pending) = .empty;
    defer edges.deinit(gpa);
    var refs: std.ArrayList(Reference) = .empty;
    try readSources(gpa, a, g, options, reader, scratch, progress, &recorder, cached, .{ .code_enabled = code_enabled, .inactive = inactive, .base_ctx = base_ctx, .test_files = test_files, .reexports = reexports, .java_packages = java_packages, .index = index, .position = position }, &edges, &refs, &unsupported);
    return finish(a, g, options.manifests, reader, progress, &recorder, edges.items, &refs, &deps, &unsupported);
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
            // A name `scan` would refuse (a backslash, or `C:` at the root) is not listed.
            if (!path.valid(full) or !keep(context, full, entry.kind)) continue;
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

/// Module identities, workspaces and dependency declarations, in path order.
fn readManifests(w: std.mem.Allocator, a: std.mem.Allocator, g: *Graph, options: Options, reader: anytype, scratch: *std.heap.ArenaAllocator, progress: *diagnostics.Progress, modules: *std.ArrayList(resolver.GoModule), workspaces: *std.ArrayList(config_module.Workspace), deps: *std.ArrayList(Dependency), unsupported: *std.ArrayList(t.UnsupportedReference)) !void {
    for (g.paths) |p| {
        const is_mod = std.mem.eql(u8, path.base(p), "go.mod");
        const is_work = std.mem.eql(u8, path.base(p), "go.work");
        if (!is_work and !is_mod and (!manifests.supported(p) or !options.manifests)) continue;
        const s = scratch.allocator();
        defer _ = scratch.reset(.{ .retain_with_limit = scratch_kept });
        const text = (try @TypeOf(reader.*).readFile(s, reader, p)) orelse continue;
        progress.at(.manifests, p);
        if (is_mod or is_work) {
            // A module file that does not parse gives neither routing nor declarations.
            const parsed = config_module.parse(w, path.dir(p), try w.dupe(u8, text)) catch |err| {
                try progress.tolerate(err);
                continue;
            };
            if (is_mod) if (parsed.name) |name| {
                try modules.append(w, .{ .root = path.dir(p), .name = name, .requires = parsed.requires, .replacements = parsed.replacements });
            };
            if (is_work) try workspaces.append(w, .{ .root = path.dir(p), .uses = parsed.uses, .replacements = parsed.replacements });
        }
        if (options.manifests and manifests.supported(p)) {
            const declared = manifests.readSupported(s, p, text) catch |err| {
                try progress.tolerate(err);
                continue;
            };
            if (options.strict_imports and declared.unsupported.len > 0) {
                progress.offset = declared.unsupported[0].offset;
                return error.UnsupportedImport;
            }
            for (declared.unsupported) |record| try unsupported.append(a, .{ .from = p, .offset = record.offset, .expression = record.expression });
            for (declared.dependencies) |dep| try deps.append(a, .{ .manifest = p, .name = try a.dupe(u8, dep.name), .source = try a.dupe(u8, dep.source), .requirement = try a.dupe(u8, dep.requirement), .group = try a.dupe(u8, dep.group), .origin = dep.origin });
        }
    }
}

/// Recover sources after language indexes are complete; read buffers stay local.
fn readSources(gpa: std.mem.Allocator, a: std.mem.Allocator, g: *Graph, options: Options, reader: anytype, scratch: *std.heap.ArenaAllocator, progress: *diagnostics.Progress, recorder: *Recorder, cached: []?t.Recovery, indexes: anytype, edges: *std.ArrayList(Graph.Pending), refs: *std.ArrayList(Reference), unsupported: *std.ArrayList(t.UnsupportedReference)) !void {
    std.debug.assert(cached.len == 0 or cached.len == g.paths.len);
    for (g.paths, 0..) |p, file_index| {
        if (indexes.inactive.contains(p)) continue;
        const language = languageOf(p);
        const readable = kindsOf(p);
        const code = indexes.code_enabled and readable.contains(.import);
        const lexed = readable.contains(.import) and recorder.wants(file_index);
        const links = enabled(options, .link) and readable.contains(.link);
        const assets = enabled(options, .asset) and readable.contains(.asset);
        if (!code and !lexed and !links and !assets) continue;
        const s = scratch.allocator();
        const prior = if (cached.len > 0) cached[file_index] else null;
        const text = (if (prior != null) "" else try @TypeOf(reader.*).readFile(s, reader, p)) orelse {
            _ = scratch.reset(.{ .retain_with_limit = scratch_kept });
            continue;
        };
        var ctx = indexes.base_ctx;
        ctx.allocator = s;
        ctx.python_reexports = &indexes.reexports;
        ctx.java_packages = &indexes.java_packages;
        const from: u32 = @intCast(file_index);
        if (lexed and !code) {
            progress.at(.imports, p);
            _ = extract(s, language.?, text, recorder, file_index, p) catch |err| try progress.tolerate(err);
        }
        if (code) {
            var seen: std.AutoHashMapUnmanaged(struct { usize, u32 }, void) = .empty;
            progress.at(.imports, p);
            const recovery = prior orelse extract(s, language.?, text, recorder, file_index, p) catch |err| empty: {
                try progress.tolerate(err);
                break :empty t.Recovery{};
            };
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
                const kind: Kind = if (spec.kind == .@"test" or testFile(options, indexes.test_files, language.?, p)) .@"test" else spec.kind;
                const targets = ctx.targets(p, language.?, spec) catch |err| unresolved: {
                    progress.offset = spec.offset;
                    try progress.tolerate(err);
                    break :unresolved &.{};
                };
                try refs.append(a, .{ .from = p, .name = if (prior != null) spec.name else try a.dupe(u8, spec.name), .offset = spec.offset, .member = if (spec.member) |member| (if (prior != null) member else try a.dupe(u8, member)) else null, .resolved = targets.len > 0, .kind = kind, .dead = spec.dead });
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
                    const edge_kind: Kind = if (kind == .@"test" or (code_kind_module.targetDecides(language.?, spec.form) and testFile(options, indexes.test_files, language.?, target))) .@"test" else kind;
                    if (!enabled(options, edge_kind)) continue;
                    const to = indexes.position.get(target).?;
                    const entry = try seen.getOrPut(s, .{ spec.offset, to });
                    if (!entry.found_existing) try edges.append(gpa, .{ .from = from, .to = to, .kind = edge_kind });
                }
            }
        }
        if (links) {
            progress.at(.links, p);
            for (try recover.links(s, text)) |spec| {
                if (try recover.linkTarget(ctx, &indexes.index, p, spec)) |target| if (!std.mem.eql(u8, target, p)) try edges.append(gpa, .{ .from = from, .to = indexes.position.get(target).?, .kind = .link });
            }
        }
        if (assets) {
            progress.at(.assets, p);
            for (try recover.assets(s, text)) |spec| {
                const target = (try ctx.candidate("", spec.name, &.{""})) orelse (try ctx.candidate(path.dir(p), spec.name, &.{""})) orelse continue;
                if (!std.mem.eql(u8, target, p)) try edges.append(gpa, .{ .from = from, .to = indexes.position.get(target).?, .kind = .asset });
            }
        }
        _ = scratch.reset(.{ .retain_with_limit = scratch_kept });
    }
}

/// A file whose every import is `test`: by its language's convention, Rust
/// cfg(test) propagation or the caller's `test_paths`.
fn testFile(options: Options, rust_tests: std.StringHashMapUnmanaged(void), language: Language, file: []const u8) bool {
    if (rust_tests.contains(file) or code_kind_module.file(language, file)) return true;
    for (options.test_paths) |pattern| if (check_module.matches(pattern, file)) return true;
    return false;
}

/// Publish sorted graph records only after every read succeeds.
fn finish(a: std.mem.Allocator, g: *Graph, manifests_enabled: bool, reader: anytype, progress: *diagnostics.Progress, recorder: *Recorder, edges: []Graph.Pending, refs: *std.ArrayList(Reference), deps: *std.ArrayList(Dependency), unsupported: *std.ArrayList(t.UnsupportedReference)) !graph_module.Graph {
    progress.at(.graph, null);
    g.edges = try Graph.coalescePending(a, g.paths, edges);
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
    // Each extractor is in source order; manifests are read before sources.
    std.mem.sort(t.UnsupportedReference, unsupported.items, {}, struct {
        fn less(_: void, x: t.UnsupportedReference, y: t.UnsupportedReference) bool {
            const from = std.mem.order(u8, x.from.?, y.from.?);
            return from == .lt or (from == .eq and x.offset < y.offset);
        }
    }.less);
    g.unsupported = try unsupported.toOwnedSlice(a);
    g.tokens = try recorder.finish();
    g.references = try refs.toOwnedSlice(a);
    g.dependencies = try deps.toOwnedSlice(a);
    g.manifests = manifests_enabled;
    g.unread = try reader.unreadPaths(a, &g.files);
    std.mem.sort(diagnostics.InvalidFile, progress.invalid.items, {}, struct {
        fn less(_: void, x: diagnostics.InvalidFile, y: diagnostics.InvalidFile) bool {
            const order = std.mem.order(u8, x.path, y.path);
            return order == .lt or (order == .eq and (x.offset orelse 0) < (y.offset orelse 0));
        }
    }.less);
    g.invalid = progress.invalid.items;
    return Graph.owner(graph_module.Graph, g);
}
