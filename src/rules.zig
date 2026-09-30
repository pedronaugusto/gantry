//! Rules are caller data. All matching restrictions report, in rule order.
const std = @import("std");
const t = @import("types.zig");
const Graph = @import("Graph.zig");
pub const Layer = struct { name: []const u8, patterns: []const []const u8 };
pub const OrderedLayers = struct { name: []const u8, layers: []const Layer, default_layer: usize = 0 };
pub const EdgeRule = struct { name: []const u8, from: []const u8 = "**", to: []const u8 = "**", kind: ?t.Kind = null };
/// An allowance exempts an edge from just the named rule. It cannot waive
/// cycles or required paths. A layer name here means OrderedLayers.name.
pub const Allow = struct { rule: []const u8, from: []const u8 = "**", to: []const u8 = "**" };
pub const ReferenceRule = struct {
    name: []const u8,
    from: []const u8 = "**",
    target: []const u8 = "**",
    member: ?[]const u8 = null,
    /// false covers every import, true just those not resolved to files.
    unresolved_only: bool = false,
    except_targets: []const []const u8 = &.{},
    except_from: []const []const u8 = &.{},
};
pub const Required = struct { name: []const u8, paths: []const []const u8 };
pub const Rules = struct {
    ordered: []const OrderedLayers = &.{},
    forbidden: []const EdgeRule = &.{},
    allowed: []const Allow = &.{},
    /// Like forbidden with an implicit from = **.
    nothing_imports: []const EdgeRule = &.{},
    references: []const ReferenceRule = &.{},
    required: []const Required = &.{},
    /// null permits cycles; a name enables and identifies the rule.
    no_cycles: ?[]const u8 = null,
};
pub const Violation = struct {
    rule: []const u8,
    reason: enum { upward, forbidden, entry, reference, missing, cycle },
    edge: ?t.Edge = null,
    reference: ?t.Reference = null,
    path: ?[]const u8 = null,
};
fn allowed(rules: Rules, name: []const u8, e: t.Edge) bool {
    for (rules.allowed) |r| if (std.mem.eql(u8, r.rule, name) and matches(r.from, e.from) and matches(r.to, e.to)) return true;
    return false;
}
fn layer(r: OrderedLayers, path: []const u8) usize {
    for (r.layers, 0..) |item, i| for (item.patterns) |pattern| if (matches(pattern, path)) return i;
    return r.default_layer;
}
pub fn check(g: *const Graph, a: std.mem.Allocator, rules: Rules) ![]const Violation {
    var out: std.ArrayList(Violation) = .empty;
    errdefer out.deinit(a);
    for (rules.ordered) |r| for (g.edges) |e| {
        if (layer(r, e.to) > layer(r, e.from) and !allowed(rules, r.name, e)) try out.append(a, .{ .rule = r.name, .reason = .upward, .edge = e });
    };
    for (rules.forbidden) |r| for (g.edges) |e| {
        if (matches(r.from, e.from) and matches(r.to, e.to) and (r.kind == null or r.kind.? == e.kind) and !allowed(rules, r.name, e)) try out.append(a, .{ .rule = r.name, .reason = .forbidden, .edge = e });
    };
    for (rules.nothing_imports) |r| for (g.edges) |e| {
        if (matches(r.to, e.to) and (r.kind == null or r.kind.? == e.kind) and !allowed(rules, r.name, e)) try out.append(a, .{ .rule = r.name, .reason = .entry, .edge = e });
    };
    for (rules.references) |r| for (g.references) |ref| {
        if (!matches(r.from, ref.from) or !matches(r.target, ref.name) or (r.unresolved_only and ref.resolved)) continue;
        if (r.member) |member| {
            if (ref.member == null or !matches(member, ref.member.?)) continue;
        } else if (ref.member != null) continue;
        var except = false;
        for (r.except_targets) |target| if (matches(target, ref.name)) {
            except = true;
        };
        for (r.except_from) |from| if (matches(from, ref.from)) {
            except = true;
        };
        if (!except) try out.append(a, .{ .rule = r.name, .reason = .reference, .reference = ref });
    };
    for (rules.required) |r| for (r.paths) |path| if (!g.files.contains(path)) {
        try out.append(a, .{ .rule = r.name, .reason = .missing, .path = path });
    };
    if (rules.no_cycles) |name| {
        var analysis = try g.analyze(a);
        defer analysis.deinit();
        for (analysis.cycles) |cycle| {
            // Return the first witness edge; its paths borrow the graph, not analysis.
            for (g.edges) |e| if (std.mem.eql(u8, e.from, cycle.path[0]) and std.mem.eql(u8, e.to, cycle.path[1])) {
                try out.append(a, .{ .rule = name, .reason = .cycle, .edge = e });
                break;
            };
        }
    }
    return out.toOwnedSlice(a);
}
/// Slash-separated globs: * and ? within components, ** as a complete
/// component across zero or more directories. A pattern without '/' matches
/// the basename. Byte and case exact on every platform; no regex engine.
pub fn matches(pattern: []const u8, path: []const u8) bool {
    if (std.mem.indexOfScalar(u8, pattern, '/') == null and !std.mem.eql(u8, pattern, "**")) return component(pattern, @import("path.zig").base(path));
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
