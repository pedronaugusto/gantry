//! Rules are caller data. All matching restrictions report, in rule order.
const std = @import("std");
const t = @import("types.zig");
pub const Layer = struct { name: []const u8, patterns: []const []const u8 };
pub const OrderedLayers = struct {
    name: []const u8,
    layers: []const Layer,
    /// The layer of a path no pattern names; unused when `transitive`.
    default_layer: usize = 0,
    /// Follow chains of any length, as import-linter's layers contract
    /// does: a path no pattern names has no layer and chains pass through
    /// it, and each layered file reports, for each higher layer one of its
    /// chains reaches through unlayered files alone, the shortest such
    /// chain. A chain through another layered file is that file's.
    transitive: bool = false,
};
pub const EdgeRule = struct {
    name: []const u8,
    from: []const u8 = "**",
    to: []const u8 = "**",
    /// The edges this rule restricts, or a transitive rule follows.
    kind: ?t.Kind = null,
    /// In `forbidden`, restrict chains of any length: each file matching
    /// `from` from which edges lead, through any files, to one matching
    /// `to` reports the shortest such chain. An allowance for the rule
    /// takes its edges out of the chains. `nothing_imports` is already
    /// transitive: every chain into a file ends in an edge into it.
    transitive: bool = false,
};
/// Files that must be reachable: every file matching `files` that no
/// chain from an entry reaches, and that is no entry itself, reports.
/// An orphan, with no edges at all, is unreachable unless it is an entry.
pub const Reachable = struct {
    name: []const u8,
    /// Path patterns of the files the chains start from.
    entries: []const []const u8,
    files: []const u8 = "**",
    /// The edges chains follow; null follows every kind.
    kind: ?t.Kind = null,
};
/// An allowance exempts an edge from just the named rule. It cannot waive
/// cycles or required paths. A layer name here means OrderedLayers.name.
pub const Allow = struct { rule: []const u8, from: []const u8 = "**", to: []const u8 = "**", kind: ?t.Kind = null };
pub const ReferenceRule = struct {
    name: []const u8,
    from: []const u8 = "**",
    target: []const u8 = "**",
    member: ?[]const u8 = null,
    /// Filter raw spellings, then optionally match the normalized path relative
    /// to the importer. This can restrict even an import of a missing file.
    suffix: ?[]const u8 = null,
    relative: bool = false,
    /// false covers every import, true just those not resolved to files.
    unresolved_only: bool = false,
    kind: ?t.Kind = null,
    except_targets: []const []const u8 = &.{},
    except_from: []const []const u8 = &.{},
};
pub const Required = struct { name: []const u8, paths: []const []const u8 };
/// A token only its owners may spell: an identifier, or the value of a
/// string literal after its escapes. Comments and character literals never
/// match. `token` is exact, or a pattern where `*` matches any run of bytes
/// and `?` one byte. A scan records occurrences only for the rules passed
/// in `Options.tokens`.
pub const TokenRule = struct {
    name: []const u8,
    kind: t.Token.Kind = .identifier,
    token: []const u8,
    /// Path patterns, as layers use them, of the files that may spell it.
    owners: []const []const u8 = &.{},
};
pub const Rules = struct {
    ordered: []const OrderedLayers = &.{},
    forbidden: []const EdgeRule = &.{},
    allowed: []const Allow = &.{},
    /// Like forbidden with an implicit from = **.
    nothing_imports: []const EdgeRule = &.{},
    references: []const ReferenceRule = &.{},
    required: []const Required = &.{},
    reachable: []const Reachable = &.{},
    /// Tokens outside their owners' files; the graph must have been scanned
    /// with the same rules in `Options.tokens`.
    tokens: []const TokenRule = &.{},
    /// null permits cycles; a name enables and identifies the rule.
    no_cycles: ?[]const u8 = null,
};
pub const Violation = struct {
    rule: []const u8,
    reason: enum { upward, forbidden, entry, reference, missing, cycle, token, unreached },
    /// The edge a direct rule restricts, or a chain's first edge.
    edge: ?t.Edge = null,
    reference: ?t.Reference = null,
    token: ?t.Token = null,
    /// A missing required path, an unreachable file, or the file a chain
    /// ends in.
    path: ?[]const u8 = null,
    /// A transitive rule's witness, its first file to its last; empty for
    /// every other finding. `free` releases it with the findings.
    chain: []const []const u8 = &.{},
};
/// Frees findings and the chains of transitive ones, which `check`
/// allocates as one block in finding order.
pub fn free(a: std.mem.Allocator, findings: []const Violation) void {
    var first: ?[*]const []const u8 = null;
    var total: usize = 0;
    for (findings) |finding| if (finding.chain.len > 0) {
        if (first == null) first = finding.chain.ptr;
        total += finding.chain.len;
    };
    if (first) |block| a.free(block[0..total]);
    a.free(findings);
}
fn allowed(rules: Rules, name: []const u8, e: t.Edge) bool {
    for (rules.allowed) |r| if (std.mem.eql(u8, r.rule, name) and matches(r.from, e.from) and matches(r.to, e.to) and (r.kind == null or r.kind.? == e.kind)) return true;
    return false;
}
fn layer(r: OrderedLayers, path: []const u8) usize {
    return named(r, path) orelse r.default_layer;
}
fn named(r: OrderedLayers, path: []const u8) ?usize {
    for (r.layers, 0..) |item, i| for (item.patterns) |pattern| if (matches(pattern, path)) return i;
    return null;
}
/// Findings borrow graph storage, rule names and required-path strings.
/// Keep the graph and those caller strings alive until findings are freed
/// with `free`; a.free alone frees them when no rule is transitive.
pub fn check(g: anytype, a: std.mem.Allocator, rules: Rules) ![]const Violation {
    var out: Findings = .{ .a = a };
    errdefer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(a);
    defer scratch.deinit();
    var walks: ?Walks = null;
    for (rules.ordered) |r| {
        if (r.transitive) {
            if (walks == null) walks = try .init(scratch.allocator(), g.paths(), g.edges());
            try walks.?.layers(&out, g.edges(), rules, r);
        } else for (g.edges()) |e| {
            if (layer(r, e.to) > layer(r, e.from) and !allowed(rules, r.name, e)) try out.append(.{ .rule = r.name, .reason = .upward, .edge = e });
        }
    }
    for (rules.forbidden) |r| {
        if (r.transitive) {
            if (walks == null) walks = try .init(scratch.allocator(), g.paths(), g.edges());
            try walks.?.forbidden(&out, g.edges(), rules, r);
        } else for (g.edges()) |e| {
            if (matches(r.from, e.from) and matches(r.to, e.to) and (r.kind == null or r.kind.? == e.kind) and !allowed(rules, r.name, e)) try out.append(.{ .rule = r.name, .reason = .forbidden, .edge = e });
        }
    }
    for (rules.nothing_imports) |r| for (g.edges()) |e| {
        if (matches(r.to, e.to) and (r.kind == null or r.kind.? == e.kind) and !allowed(rules, r.name, e)) try out.append(.{ .rule = r.name, .reason = .entry, .edge = e });
    };
    for (rules.references) |r| for (g.references()) |ref| {
        if (!matches(r.from, ref.from) or (r.unresolved_only and ref.resolved) or (r.kind != null and r.kind.? != ref.kind)) continue;
        if (r.suffix) |suffix| if (!std.mem.endsWith(u8, ref.name, suffix)) continue;
        var normalized: ?[]const u8 = null;
        defer if (normalized) |path| a.free(path);
        if (r.relative) {
            const dir = @import("path.zig").dir(ref.from);
            const raw = try std.mem.join(a, "/", if (dir.len == 0) &.{ref.name} else &.{ dir, ref.name });
            defer a.free(raw);
            normalized = @import("path.zig").normalize(a, raw) catch |err| switch (err) {
                error.InvalidPath => null,
                else => return err,
            };
        }
        const target_name = normalized orelse ref.name;
        if (!matchesFull(r.target, target_name)) continue;
        if (r.member) |member| {
            if (ref.member == null or !matches(member, ref.member.?)) continue;
        } else if (ref.member != null) continue;
        var except = false;
        for (r.except_targets) |target| if (matchesFull(target, target_name)) {
            except = true;
        };
        for (r.except_from) |from| if (matches(from, ref.from)) {
            except = true;
        };
        if (!except) try out.append(.{ .rule = r.name, .reason = .reference, .reference = ref });
    };
    for (rules.tokens) |r| for (g.tokens()) |token| {
        if (token.kind != r.kind or !matchesToken(r.token, token.text)) continue;
        for (r.owners) |owner| {
            if (matches(owner, token.path)) break;
        } else try out.append(.{ .rule = r.name, .reason = .token, .token = token });
    };
    for (rules.required) |r| for (r.paths) |path| if (!g.contains(path)) {
        try out.append(.{ .rule = r.name, .reason = .missing, .path = path });
    };
    if (rules.no_cycles) |name| {
        var analysis = try g.analyze(a);
        defer analysis.deinit();
        for (analysis.cycles()) |cycle| {
            // Return the first witness edge; its paths borrow the graph, not analysis.
            var low: usize = 0;
            var high = g.edges().len;
            const key: t.Edge = .{ .from = cycle.path[0], .to = cycle.path[1] };
            while (low < high) {
                const mid = low + (high - low) / 2;
                if (t.edgesLess({}, g.edges()[mid], key)) low = mid + 1 else high = mid;
            }
            try out.append(.{ .rule = name, .reason = .cycle, .edge = g.edges()[low] });
        }
    }
    for (rules.reachable) |r| {
        if (walks == null) walks = try .init(scratch.allocator(), g.paths(), g.edges());
        try walks.?.unreached(&out, g.edges(), r);
    }
    return out.finish();
}
/// Findings, and their chains gathered into one block for `free`.
const Findings = struct {
    a: std.mem.Allocator,
    items: std.ArrayList(Violation) = .empty,
    chains: std.ArrayList([]const u8) = .empty,
    /// Where each chain lies in `chains`, by finding.
    spans: std.ArrayList(struct { finding: usize, start: usize, len: usize }) = .empty,
    fn append(f: *Findings, v: Violation) !void {
        try f.items.append(f.a, v);
    }
    fn appendChain(f: *Findings, v: Violation, paths: []const []const u8, nodes: []const u32) !void {
        try f.spans.append(f.a, .{ .finding = f.items.items.len, .start = f.chains.items.len, .len = nodes.len });
        for (nodes) |node| try f.chains.append(f.a, paths[node]);
        try f.items.append(f.a, v);
    }
    fn finish(f: *Findings) ![]const Violation {
        const block = try f.chains.toOwnedSlice(f.a);
        errdefer f.a.free(block);
        const items = try f.items.toOwnedSlice(f.a);
        for (f.spans.items) |span| items[span.finding].chain = block[span.start..][0..span.len];
        f.spans.deinit(f.a);
        return items;
    }
    fn deinit(f: *Findings) void {
        f.items.deinit(f.a);
        f.chains.deinit(f.a);
        f.spans.deinit(f.a);
    }
};
/// The graph as adjacency arrays labelled by edge index, for the rules
/// that follow chains. Lives in the check's scratch.
const Walks = struct {
    a: std.mem.Allocator,
    paths: []const []const u8,
    forward: walk.Adjacency,
    backward: walk.Adjacency,
    const walk = @import("reach.zig");
    fn init(a: std.mem.Allocator, paths: []const []const u8, edges: []const t.Edge) !Walks {
        var ids: std.StringHashMapUnmanaged(u32) = .empty;
        if (paths.len >= std.math.maxInt(u32)) return error.OutOfMemory;
        try ids.ensureTotalCapacity(a, @intCast(paths.len));
        for (paths, 0..) |path, i| ids.putAssumeCapacity(path, @intCast(i));
        const from = try a.alloc(u32, edges.len);
        const to = try a.alloc(u32, edges.len);
        for (edges, from, to) |e, *v, *w| {
            v.* = ids.get(e.from).?;
            w.* = ids.get(e.to).?;
        }
        return .{ .a = a, .paths = paths, .forward = try .init(a, paths.len, from, to, true), .backward = try .init(a, paths.len, to, from, true) };
    }
    /// Which edges a rule's chains follow: its kind, less its allowances.
    fn follow(w: Walks, edges: []const t.Edge, rules: Rules, name: []const u8, kind: ?t.Kind) ![]const bool {
        const result = try w.a.alloc(bool, edges.len);
        for (edges, result) |e, *dest| dest.* = (kind == null or kind.? == e.kind) and !allowed(rules, name, e);
        return result;
    }
    fn forbidden(w: Walks, out: *Findings, edges: []const t.Edge, rules: Rules, r: EdgeRule) !void {
        const filter: walk.Filter = .{ .follow = try w.follow(edges, rules, r.name, r.kind) };
        const targets = try w.a.alloc(bool, w.paths.len);
        for (w.paths, targets) |path, *dest| dest.* = matches(r.to, path);
        const dist = try w.a.alloc(u32, w.paths.len);
        try walk.distances(w.a, w.backward, targets, filter, dist);
        var nodes: std.ArrayList(u32) = .empty;
        for (w.paths, 0..) |path, v| if (matches(r.from, path)) {
            nodes.clearRetainingCapacity();
            const first = try walk.chain(w.a, w.forward, dist, filter, @intCast(v), &nodes) orelse continue;
            try out.appendChain(.{ .rule = r.name, .reason = .forbidden, .edge = edges[first], .path = w.paths[nodes.items[nodes.items.len - 1]] }, w.paths, nodes.items);
        };
    }
    fn layers(w: Walks, out: *Findings, edges: []const t.Edge, rules: Rules, r: OrderedLayers) !void {
        const filter_edges = try w.follow(edges, rules, r.name, null);
        const place = try w.a.alloc(?usize, w.paths.len);
        const passable = try w.a.alloc(bool, w.paths.len);
        for (w.paths, place, passable) |path, *at, *through| {
            at.* = named(r, path);
            through.* = at.* == null;
        }
        const filter: walk.Filter = .{ .follow = filter_edges, .passable = passable };
        // Distances to each layer's files, through unlayered files alone.
        const dist = try w.a.alloc([]u32, r.layers.len);
        const targets = try w.a.alloc(bool, w.paths.len);
        for (dist, 0..) |*d, j| {
            for (place, targets) |at, *dest| dest.* = at == j;
            d.* = try w.a.alloc(u32, w.paths.len);
            try walk.distances(w.a, w.backward, targets, filter, d.*);
        }
        var nodes: std.ArrayList(u32) = .empty;
        for (place, 0..) |at, v| if (at) |low| for (low + 1..r.layers.len) |j| {
            nodes.clearRetainingCapacity();
            const first = try walk.chain(w.a, w.forward, dist[j], filter, @intCast(v), &nodes) orelse continue;
            try out.appendChain(.{ .rule = r.name, .reason = .upward, .edge = edges[first], .path = w.paths[nodes.items[nodes.items.len - 1]] }, w.paths, nodes.items);
        };
    }
    fn unreached(w: Walks, out: *Findings, edges: []const t.Edge, r: Reachable) !void {
        const marks = try w.a.alloc(bool, w.paths.len);
        @memset(marks, false);
        var queue: std.ArrayList(u32) = .empty;
        for (w.paths, 0..) |path, v| for (r.entries) |entry| if (matches(entry, path)) {
            marks[v] = true;
            try queue.append(w.a, @intCast(v));
            break;
        };
        var head: usize = 0;
        while (head < queue.items.len) : (head += 1) {
            const v = queue.items[head];
            for (w.forward.offsets[v]..w.forward.offsets[v + 1]) |k| {
                const next = w.forward.targets[k];
                if (marks[next] or (r.kind != null and edges[w.forward.labels[k]].kind != r.kind.?)) continue;
                marks[next] = true;
                try queue.append(w.a, next);
            }
        }
        for (w.paths, marks) |path, mark| if (!mark and matches(r.files, path)) try out.append(.{ .rule = r.name, .reason = .unreached, .path = path });
    }
};
/// Slash-separated globs: * and ? within components, ** as a complete
/// component across zero or more directories. A pattern without '/' matches
/// the basename. Byte and case exact on every platform; no regex engine.
pub fn matches(pattern: []const u8, path: []const u8) bool {
    if (std.mem.indexOfScalar(u8, pattern, '/') == null and !std.mem.eql(u8, pattern, "**")) return component(pattern, @import("path.zig").base(path));
    return matchesFull(pattern, path);
}
/// A raw import name is matched in full; unlike file rules, an unqualified
/// pattern does not also match the basename of a package path.
fn matchesFull(pattern: []const u8, path: []const u8) bool {
    var pi: usize = 0;
    var si: usize = 0;
    var retry_pattern: ?usize = null;
    var retry_path: usize = 0;
    while (true) {
        const pe = end(pattern, pi);
        const se = end(path, si);
        if (pi < pattern.len and std.mem.eql(u8, pattern[pi..pe], "**")) {
            pi = if (pe < pattern.len) pe + 1 else pattern.len;
            if (pi == pattern.len) return true;
            retry_pattern = pi;
            retry_path = si;
            continue;
        }
        if (pi == pattern.len and si == path.len) return true;
        if (pi < pattern.len and si < path.len and component(pattern[pi..pe], path[si..se])) {
            pi = if (pe < pattern.len) pe + 1 else pattern.len;
            si = if (se < path.len) se + 1 else path.len;
            continue;
        }
        if (retry_pattern) |rp| {
            if (retry_path == path.len) return false;
            const re = end(path, retry_path);
            retry_path = if (re < path.len) re + 1 else path.len;
            si = retry_path;
            pi = rp;
        } else return false;
    }
}
/// A token rule's text: `*` matches any run of bytes, including `/`, and
/// `?` one byte; every other byte matches itself.
pub fn matchesToken(pattern: []const u8, text: []const u8) bool {
    return component(pattern, text);
}
fn end(s: []const u8, i: usize) usize {
    return std.mem.indexOfScalarPos(u8, s, i, '/') orelse s.len;
}
fn component(pattern: []const u8, text: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    var star: ?usize = null;
    var retry: usize = 0;
    while (j < text.len) {
        if (i < pattern.len and (pattern[i] == '?' or pattern[i] == text[j])) {
            i += 1;
            j += 1;
        } else if (i < pattern.len and pattern[i] == '*') {
            star = i;
            i += 1;
            retry = j;
        } else if (star) |s| {
            retry += 1;
            j = retry;
            i = s + 1;
        } else return false;
    }
    while (i < pattern.len and pattern[i] == '*') : (i += 1) {}
    return i == pattern.len;
}
