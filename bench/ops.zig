//! Every public gantry operation, timed in process on one revision.
//! `ops --list` names the workloads this revision has; `ops <workload> <arg>`
//! runs one and prints five-column rows: side, workload, metric, value, unit.
//! In-memory workloads take a size (small, medium, large) or a fixture file
//! and repeat the operation for 200 ms after one untimed warm-up; fixture
//! construction stays outside the clock. Directory workloads time their
//! phases once each: the quiet pass times the whole process from outside.
const smoke = @import("bench_options").smoke;
const std = @import("std");
const gantry = @import("gantry");
const api = @import("api.zig");

const has_tokens = @hasField(gantry.Options, "tokens");
const has_diagnostic = @hasDecl(gantry, "scanWithDiagnostic");
const has_match_token = @hasDecl(gantry.rules, "matchesToken");
const budget_ns: i96 = 200 * std.time.ns_per_ms;

const Out = struct {
    writer: *std.Io.Writer,
    workload: []const u8,
    fn row(o: Out, metric: []const u8, value: anytype, unit: []const u8) !void {
        const T = @TypeOf(value);
        if (T == f64) try o.writer.print("gantry\t{s}\t{s}\t{d:.3}\t{s}\n", .{ o.workload, metric, value, unit }) else try o.writer.print("gantry\t{s}\t{s}\t{d}\t{s}\n", .{ o.workload, metric, value, unit });
    }
    fn count(o: Out, metric: []const u8, value: usize) !void {
        try o.row(metric, value, "count");
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var buffer: [16384]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const w = &stdout.interface;
    defer w.flush() catch {};
    if (args.len == 2 and std.mem.eql(u8, args[1], "--list")) return list(w);
    if (args.len != 3) return error.ExpectedWorkloadAndArgument;
    const name: []const u8 = args[1];
    const arg: []const u8 = args[2];
    const out: Out = .{ .writer = w, .workload = name };
    if (std.mem.startsWith(u8, name, "imports/")) return importsWorkload(gpa, io, out, std.meta.stringToEnum(gantry.Language, name["imports/".len..]) orelse return error.UnknownLanguage, arg);
    if (std.mem.startsWith(u8, name, "manifests/")) return manifestWorkload(gpa, io, out, name["manifests/".len..], arg);
    if (std.mem.startsWith(u8, name, "process/")) return processWorkload(gpa, io, out, name["process/".len..], arg);
    const n = try size(arg);
    if (std.mem.startsWith(u8, name, "rules/")) return rulesWorkload(gpa, io, out, name["rules/".len..], n);
    if (std.mem.startsWith(u8, name, "scan/")) return scanWorkload(gpa, io, out, name["scan/".len..], n);
    if (std.mem.startsWith(u8, name, "graph/")) return graphWorkload(gpa, io, out, name["graph/".len..], n);
    if (std.mem.eql(u8, name, "path/normalize") or std.mem.startsWith(u8, name, "match/")) return helperWorkload(gpa, io, out, name, n);
    return error.UnknownWorkload;
}

fn list(w: *std.Io.Writer) !void {
    inline for (comptime std.meta.tags(gantry.Language)) |l| try w.print("imports/{s}\n", .{@tagName(l)});
    // A format is listed when this revision reads it: probe with its smallest file.
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    for (manifest_probes) |probe| {
        if (gantry.manifests.parse(arena.allocator(), probe[0], probe[1])) |_| {
            try w.print("manifests/{s}\n", .{probe[0]});
        } else |_| {}
    }
    for ([_][]const u8{ "ordered", "forbidden", "allowed", "nothing-imports", "references", "required", "cycles" }) |f| try w.print("rules/{s}\n", .{f});
    if (has_tokens) try w.writeAll("rules/tokens\n");
    try w.writeAll("scan/memory\nscan/links\nscan/assets\n");
    if (has_diagnostic) try w.writeAll("scan/diagnostic\n");
    if (has_tokens) try w.writeAll("scan/tokens\n");
    try w.writeAll("graph/from-edges\ngraph/analysis-init\ngraph/analyze\ngraph/aggregate\npath/normalize\nmatch/path\n");
    if (has_match_token) try w.writeAll("match/token\n");
    try w.writeAll("process/walk\nprocess/check-js\nprocess/check-python\nprocess/links\n");
    if (has_tokens) try w.writeAll("process/tokens\n");
}

const manifest_probes = [_][2][]const u8{
    .{ "package.json", "{\"dependencies\":{\"a\":\"1\"}}" },
    .{ "Cargo.toml", "[dependencies]\na = \"1\"\n" },
    .{ "pyproject.toml", "[project]\nname = \"p\"\ndependencies = [\"a>=1\"]\n" },
    .{ "go.mod", "module example.com/p\nrequire example.com/a v1.0.0\n" },
    .{ "build.zig.zon", ".{ .name = .p, .version = \"0.0.0\", .dependencies = .{ .a = .{ .path = \"a\" } }, .paths = .{\"\"} }" },
    .{ "pom.xml", "<project><dependencies><dependency><groupId>g</groupId><artifactId>a</artifactId><version>1</version></dependency></dependencies></project>" },
    .{ "build.gradle", "dependencies {\n    implementation 'g:a:1'\n}\n" },
    .{ "bench.nimble", "requires \"a >= 1.0\"\n" },
};

fn size(arg: []const u8) !usize {
    // File counts: a handful of modules, a large application, a monorepo.
    if (std.mem.eql(u8, arg, "small")) return 100;
    if (std.mem.eql(u8, arg, "medium")) return 5_000;
    if (std.mem.eql(u8, arg, "large")) return 50_000;
    return error.UnknownSize;
}

/// Repeats `op` after one untimed warm-up until the budget has passed, then
/// reports the mean. Smoke runs it once and samples no clock.
fn repeat(io: std.Io, out: Out, context: anytype, comptime op: anytype) !void {
    try op(context);
    if (smoke) return out.row("ns_per_op", @as(f64, 0), "ns");
    var iterations: usize = 0;
    const start = std.Io.Clock.awake.now(io);
    var elapsed: i96 = 0;
    while (iterations < 3 or elapsed < budget_ns) {
        try op(context);
        iterations += 1;
        elapsed = start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;
    }
    try out.row("ns_per_op", @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations)), "ns");
    try out.row("iterations", iterations, "iterations");
}

fn importsWorkload(gpa: std.mem.Allocator, io: std.Io, out: Out, language: gantry.Language, file: []const u8) !void {
    const source = try std.Io.Dir.cwd().readFileAlloc(io, file, gpa, .unlimited);
    defer gpa.free(source);
    const Ctx = struct {
        gpa: std.mem.Allocator,
        language: gantry.Language,
        source: []const u8,
        specs: usize = 0,
        fn op(c: *@This()) !void {
            var found = try gantry.imports(c.gpa, c.language, c.source);
            defer found.deinit();
            c.specs = api.specs(&found).len;
        }
    };
    var ctx: Ctx = .{ .gpa = gpa, .language = language, .source = source };
    try repeat(io, out, &ctx, Ctx.op);
    try out.row("source", source.len, "bytes");
    try out.count("imports", ctx.specs);
}

fn manifestWorkload(gpa: std.mem.Allocator, io: std.Io, out: Out, name: []const u8, file: []const u8) !void {
    const text = try std.Io.Dir.cwd().readFileAlloc(io, file, gpa, .unlimited);
    defer gpa.free(text);
    const Ctx = struct {
        gpa: std.mem.Allocator,
        name: []const u8,
        text: []const u8,
        dependencies: usize = 0,
        fn op(c: *@This()) !void {
            // parse wants an arena; it is part of the documented cost.
            var arena: std.heap.ArenaAllocator = .init(c.gpa);
            defer arena.deinit();
            c.dependencies = (try gantry.manifests.parse(arena.allocator(), c.name, c.text)).len;
        }
    };
    var ctx: Ctx = .{ .gpa = gpa, .name = name, .text = text };
    try repeat(io, out, &ctx, Ctx.op);
    try out.row("source", text.len, "bytes");
    try out.count("dependencies", ctx.dependencies);
}

/// A deterministic in-memory tree: groups of ten files, each importing the
/// previous one, the first closing a ten-file cycle and importing the
/// previous group's fifth file. Every file spells `Forbidden` once in code.
const Corpus = struct {
    arena: std.heap.ArenaAllocator,
    paths: []const []const u8,
    store: std.StringHashMapUnmanaged([]const u8) = .empty,
    edges: []const gantry.Edge = &.{},

    const Shape = enum { zig, links, assets };
    fn init(gpa: std.mem.Allocator, n: usize, shape: Shape) !Corpus {
        var c: Corpus = .{ .arena = .init(gpa), .paths = &.{} };
        errdefer c.arena.deinit();
        const a = c.arena.allocator();
        const paths = try a.alloc([]const u8, n);
        var edges: std.ArrayList(gantry.Edge) = .empty;
        for (paths, 0..) |*p, i| {
            const g = i / 10;
            const m = i % 10;
            const prev = if (m == 0) 9 else m - 1;
            switch (shape) {
                .zig => {
                    p.* = try std.fmt.allocPrint(a, "g{d}/f{d}.zig", .{ g, m });
                    const up = if (m == 0 and g > 0) try std.fmt.allocPrint(a, "const up = @import(\"../g{d}/f5.zig\");\n", .{g - 1}) else "";
                    try c.store.put(a, p.*, try std.fmt.allocPrint(a, "const Forbidden = {d};\nconst dep = @import(\"f{d}.zig\");\n{s}// {s} @import(\"fake.zig\")\nconst text = \"Forbidden @import(\\\"fake.zig\\\")\";\n", .{ i, prev, up, filler }));
                },
                .links => {
                    p.* = try std.fmt.allocPrint(a, "d{d}/m{d}.md", .{ g, m });
                    var text: std.ArrayList(u8) = .empty;
                    try text.print(a, "# Page {d}\n\n{s}\n\n", .{ i, filler });
                    for (1..6) |k| try text.print(a, "See [page {d}](m{d}.md) and read on.\n", .{ k, (m + k) % 10 });
                    try text.appendSlice(a, "\n```\n[not a link](m0.md)\n```\n\n<!-- [hidden](m1.md) -->\n");
                    try c.store.put(a, p.*, text.items);
                },
                .assets => {
                    // Even entries are text that names files; odd ones are the named images.
                    p.* = if (m % 2 == 0) try std.fmt.allocPrint(a, "a{d}/t{d}.txt", .{ g, m }) else try std.fmt.allocPrint(a, "a{d}/i{d}.svg", .{ g, m });
                    const text = if (m % 2 == 0) try std.fmt.allocPrint(a, "{s}\nicon a{d}/i{d}.svg and a{d}/i{d}.svg; missing a{d}/none.svg\n", .{ filler, g, m + 1, g, (m + 3) % 10, g }) else "<svg/>\n";
                    try c.store.put(a, p.*, text);
                },
            }
        }
        if (shape == .zig) {
            // Graph-only workloads: the same edges, as a caller would pass them.
            edges.clearRetainingCapacity();
            for (0..n) |i| {
                const g = i / 10;
                const m = i % 10;
                try edges.append(a, .{ .from = paths[i], .to = paths[g * 10 + if (m == 0) 9 else m - 1] });
                if (m == 0 and g > 0) try edges.append(a, .{ .from = paths[i], .to = paths[(g - 1) * 10 + 5] });
            }
            c.edges = edges.items;
        }
        c.paths = paths;
        return c;
    }
    fn deinit(c: *Corpus) void {
        c.arena.deinit();
    }
    fn read(store: *const std.StringHashMapUnmanaged([]const u8), p: []const u8, _: std.mem.Allocator) !?[]const u8 {
        return store.get(p);
    }
};
const filler = "comment " ** 16;

const token_rule_list = if (has_tokens) [_]gantry.rules.TokenRule{.{ .name = "owned", .token = "Forbidden", .owners = &.{"g0/**"} }} else {};

fn tokenOptions() gantry.Options {
    var options: gantry.Options = .{};
    if (has_tokens) options.tokens = &token_rule_list;
    return options;
}

fn scanCorpus(gpa: std.mem.Allocator, c: *const Corpus, options: gantry.Options) !gantry.Graph {
    return gantry.scan(gpa, c.paths, &c.store, Corpus.read, options);
}

fn rulesWorkload(gpa: std.mem.Allocator, io: std.Io, out: Out, family: []const u8, n: usize) !void {
    var corpus = try Corpus.init(gpa, n, .zig);
    defer corpus.deinit();
    var graph = try scanCorpus(gpa, &corpus, if (std.mem.eql(u8, family, "tokens")) tokenOptions() else .{});
    defer graph.deinit();
    const R = gantry.rules;
    var required: std.ArrayList([]const u8) = .empty;
    defer required.deinit(gpa);
    var names: std.heap.ArenaAllocator = .init(gpa);
    defer names.deinit();
    for (0..n / 10) |g| {
        try required.append(gpa, try std.fmt.allocPrint(names.allocator(), "g{d}/f0.zig", .{g}));
        try required.append(gpa, try std.fmt.allocPrint(names.allocator(), "g{d}/missing.zig", .{g}));
    }
    const layers = [_]R.Layer{.{ .name = "top", .patterns = &.{"**/f9.zig"} }};
    const forbid = [_]R.EdgeRule{.{ .name = "forbid", .from = "**/f5.zig", .to = "**/f4.zig" }};
    var rules: R.Rules = .{};
    if (std.mem.eql(u8, family, "ordered")) {
        rules.ordered = &.{.{ .name = "layers", .layers = &layers, .default_layer = 1 }};
    } else if (std.mem.eql(u8, family, "forbidden")) {
        rules.forbidden = &forbid;
    } else if (std.mem.eql(u8, family, "allowed")) {
        rules.forbidden = &forbid;
        rules.allowed = &.{.{ .rule = "forbid", .from = "g1*/**" }};
    } else if (std.mem.eql(u8, family, "nothing-imports")) {
        rules.nothing_imports = &.{.{ .name = "entry", .to = "**/f9.zig" }};
    } else if (std.mem.eql(u8, family, "references")) {
        rules.references = &.{.{ .name = "spelling", .target = "f3.zig" }};
    } else if (std.mem.eql(u8, family, "required")) {
        rules.required = &.{.{ .name = "present", .paths = required.items }};
    } else if (std.mem.eql(u8, family, "cycles")) {
        rules.no_cycles = "acyclic";
    } else if (has_tokens and std.mem.eql(u8, family, "tokens")) {
        rules.tokens = &token_rule_list;
    } else return error.UnknownRule;
    const Ctx = struct {
        gpa: std.mem.Allocator,
        graph: *const gantry.Graph,
        rules: R.Rules,
        findings: usize = 0,
        fn op(c: *@This()) !void {
            const findings = try c.graph.check(c.gpa, c.rules);
            defer c.gpa.free(findings);
            c.findings = findings.len;
        }
    };
    var ctx: Ctx = .{ .gpa = gpa, .graph = &graph, .rules = rules };
    try repeat(io, out, &ctx, Ctx.op);
    try out.count("files", n);
    try out.count("edges", api.edges(&graph).len);
    try out.count("findings", ctx.findings);
}

fn scanWorkload(gpa: std.mem.Allocator, io: std.Io, out: Out, mode: []const u8, n: usize) !void {
    const shape: Corpus.Shape = if (std.mem.eql(u8, mode, "links")) .links else if (std.mem.eql(u8, mode, "assets")) .assets else .zig;
    var corpus = try Corpus.init(gpa, n, shape);
    defer corpus.deinit();
    var bytes: usize = 0;
    for (corpus.paths) |p| bytes += corpus.store.get(p).?.len;
    const Ctx = struct {
        gpa: std.mem.Allocator,
        corpus: *const Corpus,
        options: gantry.Options,
        diagnostic: bool,
        edges: usize = 0,
        references: usize = 0,
        tokens: usize = 0,
        fn op(c: *@This()) !void {
            var graph = if (comptime has_diagnostic) blk: {
                if (!c.diagnostic) break :blk try scanCorpus(c.gpa, c.corpus, c.options);
                var diagnostic = gantry.ScanDiagnostic.init(c.gpa);
                defer diagnostic.deinit();
                break :blk try gantry.scanWithDiagnostic(c.gpa, c.corpus.paths, &c.corpus.store, Corpus.read, c.options, &diagnostic);
            } else try scanCorpus(c.gpa, c.corpus, c.options);
            defer graph.deinit();
            c.edges = api.edges(&graph).len;
            c.references = api.references(&graph).len;
            if (comptime has_tokens) c.tokens = graph.tokens().len;
        }
    };
    var options: gantry.Options = .{};
    if (shape == .links) options.kinds = &.{.link};
    if (shape == .assets) options.kinds = &.{.asset};
    const tokens = std.mem.eql(u8, mode, "tokens");
    if (tokens) options = tokenOptions();
    if (!tokens and !std.mem.eql(u8, mode, "memory") and !std.mem.eql(u8, mode, "diagnostic") and shape == .zig) return error.UnknownScan;
    var ctx: Ctx = .{ .gpa = gpa, .corpus = &corpus, .options = options, .diagnostic = std.mem.eql(u8, mode, "diagnostic") };
    try repeat(io, out, &ctx, Ctx.op);
    try out.row("source", bytes, "bytes");
    try out.count("files", n);
    try out.count("edges", ctx.edges);
    // Reference records changed shape between revisions; links and assets carry none before.
    if (shape == .zig) try out.count("references", ctx.references);
    if (tokens) try out.count("tokens", ctx.tokens);
}

fn graphWorkload(gpa: std.mem.Allocator, io: std.Io, out: Out, op_name: []const u8, n: usize) !void {
    var corpus = try Corpus.init(gpa, n, .zig);
    defer corpus.deinit();
    var graph = try gantry.Graph.fromEdges(gpa, corpus.paths, corpus.edges);
    defer graph.deinit();
    const Ctx = struct {
        gpa: std.mem.Allocator,
        corpus: *const Corpus,
        graph: *const gantry.Graph,
        which: enum { from_edges, analysis_init, analyze, aggregate },
        result: [2]usize = .{ 0, 0 },
        fn op(c: *@This()) !void {
            switch (c.which) {
                .from_edges => {
                    var g = try gantry.Graph.fromEdges(c.gpa, c.corpus.paths, c.corpus.edges);
                    defer g.deinit();
                    c.result = .{ api.edges(&g).len, 0 };
                },
                .analysis_init, .analyze => {
                    var analysis = if (c.which == .analyze) try c.graph.analyze(c.gpa) else try gantry.Analysis.init(c.gpa, c.corpus.paths, c.corpus.edges);
                    defer analysis.deinit();
                    c.result = .{ api.components(&analysis).len, api.cycles(&analysis).len };
                },
                .aggregate => {
                    var dirs = try c.graph.aggregate(c.gpa, 1);
                    defer dirs.deinit();
                    c.result = .{ api.nodes(&dirs).len, api.edges(&dirs).len };
                },
            }
        }
    };
    const Which = @FieldType(Ctx, "which");
    const which: Which = if (std.mem.eql(u8, op_name, "from-edges")) .from_edges else if (std.mem.eql(u8, op_name, "analysis-init")) .analysis_init else std.meta.stringToEnum(Which, op_name) orelse return error.UnknownGraphOperation;
    var ctx: Ctx = .{ .gpa = gpa, .corpus = &corpus, .graph = &graph, .which = which };
    try repeat(io, out, &ctx, Ctx.op);
    try out.count("files", n);
    try out.count("input_edges", corpus.edges.len);
    switch (which) {
        .from_edges => try out.count("edges", ctx.result[0]),
        .analysis_init, .analyze => {
            try out.count("components", ctx.result[0]);
            try out.count("cycles", ctx.result[1]);
        },
        .aggregate => {
            try out.count("directories", ctx.result[0]);
            try out.count("directory_edges", ctx.result[1]);
        },
    }
}

fn helperWorkload(gpa: std.mem.Allocator, io: std.Io, out: Out, name: []const u8, n: usize) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = try a.alloc([]const u8, n);
    for (raw, 0..) |*p, i| p.* = try std.fmt.allocPrint(a, "g{d}/./sub/../f{d}.zig", .{ i / 10, i % 10 });
    const Ctx = struct {
        gpa: std.mem.Allocator,
        raw: []const []const u8,
        which: enum { normalize, path, token },
        hits: usize = 0,
        fn op(c: *@This()) !void {
            var scratch: std.heap.ArenaAllocator = .init(c.gpa);
            defer scratch.deinit();
            c.hits = 0;
            for (c.raw) |p| switch (c.which) {
                .normalize => {
                    if (std.mem.endsWith(u8, try gantry.path.normalize(scratch.allocator(), p), "f3.zig")) c.hits += 1;
                },
                .path => {
                    if (gantry.rules.matches("g1*/**/f?.zig", p)) c.hits += 1;
                },
                .token => if (comptime has_match_token) {
                    if (gantry.rules.matchesToken("g1*f3*", p)) c.hits += 1;
                },
            };
        }
    };
    const which: @FieldType(Ctx, "which") = if (std.mem.eql(u8, name, "path/normalize")) .normalize else if (std.mem.eql(u8, name, "match/path")) .path else if (has_match_token and std.mem.eql(u8, name, "match/token")) .token else return error.UnknownHelper;
    var ctx: Ctx = .{ .gpa = gpa, .raw = raw, .which = which };
    try repeat(io, out, &ctx, Ctx.op);
    try out.count("inputs", n);
    try out.count("hits", ctx.hits);
}

/// Whole-tree workloads on a corpus directory, compared as processes with
/// other tools. Phases are reported for separating startup from analysis.
fn processWorkload(gpa: std.mem.Allocator, io: std.Io, out: Out, mode: []const u8, root: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    const start = now(io);
    const subtree: []const u8 = if (std.mem.eql(u8, mode, "check-js")) "js" else "";
    var paths = try gantry.walk(gpa, io, dir, subtree, keepUnder);
    defer paths.deinit();
    const listed = now(io);
    try out.row("walk_ms", ms(start, listed), "ms");
    try out.count("files", api.items(&paths).len);
    if (std.mem.eql(u8, mode, "walk")) return;
    var options: gantry.Options = .{};
    var rules: gantry.rules.Rules = .{};
    if (std.mem.eql(u8, mode, "check-js")) {
        rules.forbidden = &.{.{ .name = "forbid", .from = "js/**/f5.ts", .to = "js/**/f4.ts" }};
    } else if (std.mem.eql(u8, mode, "check-python")) {
        rules.forbidden = &.{.{ .name = "forbid", .from = "pkg/*/f5.py", .to = "pkg/*/f4.py" }};
    } else if (std.mem.eql(u8, mode, "links")) {
        options.kinds = &.{.link};
    } else if (has_tokens and std.mem.eql(u8, mode, "tokens")) {
        options.tokens = &corpus_token_rules;
        rules.tokens = &corpus_token_rules;
    } else return error.UnknownProcessWorkload;
    var graph = try gantry.scan(gpa, api.items(&paths), gantry.DirReader{ .io = io, .dir = dir }, gantry.DirReader.read, options);
    defer graph.deinit();
    const scanned = now(io);
    try out.row("scan_ms", ms(listed, scanned), "ms");
    if (std.mem.eql(u8, mode, "links")) {
        var links: usize = 0;
        for (api.edges(&graph)) |e| links += @intFromBool(e.kind == .link);
        return out.count("links", links);
    }
    const findings = try graph.check(gpa, rules);
    defer gpa.free(findings);
    try out.row("check_ms", ms(scanned, now(io)), "ms");
    try out.count("findings", findings.len);
}
const corpus_token_rules = if (has_tokens) [_]gantry.rules.TokenRule{.{ .name = "owned", .token = "Thing" }} else {};

fn keepUnder(subtree: []const u8, p: []const u8, kind: std.Io.File.Kind) bool {
    if (subtree.len == 0) return true;
    if (kind == .directory) return std.mem.eql(u8, p, subtree) or (std.mem.startsWith(u8, p, subtree) and p[subtree.len] == '/');
    return std.mem.startsWith(u8, p, subtree) and p.len > subtree.len and p[subtree.len] == '/';
}

var smoke_ticks = std.atomic.Value(i64).init(0);
fn now(io: std.Io) std.Io.Timestamp {
    if (smoke) return .{ .nanoseconds = smoke_ticks.fetchAdd(1, .monotonic) };
    return std.Io.Clock.awake.now(io);
}
fn ms(start: std.Io.Timestamp, end: std.Io.Timestamp) f64 {
    return @as(f64, @floatFromInt(start.durationTo(end).nanoseconds)) / 1_000_000;
}
