//! Text for the tools that lay out, draw and annotate: DOT and Mermaid
//! for a graph, JSON for a graph with its findings, SARIF for findings.
//! gantry draws nothing itself. Output is the same for the same input.
const graph_module = @import("graph.zig");
const std = @import("std");
const t = @import("types.zig");
const Graph = graph_module.Graph;
const engine = @import("rules/check.zig");
const text = @import("report/json.zig");
const Writer = std.Io.Writer;

pub const json = text.json;
pub const sarif = text.sarif;
pub const sarifWithSource = text.sarifWithSource;
pub const SarifOptions = text.SarifOptions;

pub const Cluster = enum {
    /// Every node at the top, labelled with its path.
    none,
    /// Nested boxes, one per directory, holding nodes labelled with
    /// their last component.
    directory,
    /// One box per layer in `Options.layers`, in their order, then the
    /// nodes no layer names.
    layer,
};

pub const Options = struct {
    cluster: Cluster = .none,
    /// For `.layer`: a node is in the first layer one of whose patterns
    /// matches it, as `rules.matches` reads a pattern.
    layers: []const engine.Layer = &.{},
    /// Findings whose nodes and edges are drawn in red: the files a
    /// finding names (that are nodes here), its edge, and the edges of
    /// every kind along its chain.
    findings: []const engine.Violation = &.{},
};

/// A Graphviz digraph, left to right. Nodes are quoted paths in path
/// order, then edges in the graph's order, styled by kind: `import`
/// solid, `type_only` dashed, `dynamic` dotted, `test` solid with a hollow
/// head, `link` dashed with an open head, `asset` dotted with a hollow dot.
/// For a graph of directories, pass `graph.aggregate(depth)`.
pub fn dot(gpa: std.mem.Allocator, w: *Writer, graph: *const Graph, options: Options) !void {
    try draw(.dot, gpa, w, graph, options);
}

/// A Mermaid flowchart, left to right, with the same nodes, edges and
/// clusters as `dot`. Node ids are `n` and the node's place in path order;
/// a kind other than `import` is an edge label, and a dotted line for the
/// kinds `dot` draws broken. Findings use a `finding` class and
/// `linkStyle`. Mermaid refuses more than 500 edges by default
/// (`maxEdges`); a large graph wants `dot`, or an aggregate.
pub fn mermaid(gpa: std.mem.Allocator, w: *Writer, graph: *const Graph, options: Options) !void {
    try draw(.mermaid, gpa, w, graph, options);
}

const Format = enum { dot, mermaid };
const red = "#cc0000";

fn draw(comptime format: Format, gpa: std.mem.Allocator, w: *Writer, graph: *const Graph, options: Options) !void {
    var marks = try Marks.init(gpa, graph, options.findings);
    defer marks.deinit(gpa);
    const paths = graph.paths();
    var out: Out(format) = .{ .w = w, .marks = &marks, .labels = options.cluster == .directory };
    switch (format) {
        .dot => try w.writeAll("digraph \"gantry\" {\n  rankdir=LR;\n  node [shape=box, style=rounded];\n"),
        .mermaid => {
            try w.writeAll("flowchart LR\n");
            if (marks.nodes.count() > 0) try w.writeAll("  classDef finding stroke:" ++ red ++ ",stroke-width:2px,color:" ++ red ++ "\n");
        },
    }
    switch (options.cluster) {
        .none => for (paths, 0..) |p, i| try out.node(i, p),
        .directory => {
            var open: []const u8 = "";
            for (paths, 0..) |p, i| {
                const dir = parent(p);
                while (!within(open, dir)) {
                    try out.close();
                    open = parent(open);
                }
                while (open.len != dir.len) {
                    const start = if (open.len == 0) 0 else open.len + 1;
                    open = dir[0 .. std.mem.findScalarPos(u8, dir, start, '/') orelse dir.len];
                    try out.open(open, open[start..]);
                }
                try out.node(i, p);
            }
            while (out.depth > 0) try out.close();
        },
        .layer => {
            const layer = try gpa.alloc(usize, paths.len);
            defer gpa.free(layer);
            for (paths, layer) |p, *l| l.* = firstLayer(options.layers, p);
            for (options.layers, 0..) |l, li| {
                if (std.mem.findScalar(usize, layer, li) == null) continue;
                try out.openLayer(li, l.name);
                for (paths, layer, 0..) |p, at, i| if (at == li) try out.node(i, p);
                try out.close();
            }
            for (paths, layer, 0..) |p, at, i| if (at == options.layers.len) try out.node(i, p);
        },
    }
    for (graph.edges(), 0..) |e, i| try out.edge(i, e, position(paths, e.from).?, position(paths, e.to).?);
    switch (format) {
        .dot => try w.writeAll("}\n"),
        .mermaid => if (marks.edges.count() > 0) {
            try w.writeAll("  linkStyle ");
            var it = marks.edges.iterator(.{});
            var first = true;
            while (it.next()) |i| {
                if (!first) try w.writeByte(',');
                first = false;
                try w.print("{d}", .{i});
            }
            try w.writeAll(" stroke:" ++ red ++ ",stroke-width:2px\n");
        },
    }
}

fn Out(comptime format: Format) type {
    return struct {
        const Self = @This();
        w: *Writer,
        marks: *const Marks,
        labels: bool,
        depth: usize = 0,
        clusters: usize = 0,

        fn indent(o: *Self) Writer.Error!void {
            try o.w.splatByteAll(' ', 2 * (o.depth + 1));
        }
        fn open(o: *Self, dir: []const u8, label: []const u8) Writer.Error!void {
            try o.indent();
            switch (format) {
                .dot => {
                    try o.w.writeAll("subgraph \"cluster_");
                    try dotText(o.w, dir);
                    try o.w.writeAll("\" {\n");
                    o.depth += 1;
                    try o.indent();
                    try o.w.writeAll("label=\"");
                    try dotText(o.w, label);
                    try o.w.writeAll("\";\n");
                },
                .mermaid => {
                    try o.w.print("subgraph d{d}[\"", .{o.clusters});
                    try mermaidText(o.w, label);
                    try o.w.writeAll("\"]\n");
                    o.depth += 1;
                },
            }
            o.clusters += 1;
        }
        fn openLayer(o: *Self, index: usize, name: []const u8) Writer.Error!void {
            switch (format) {
                .dot => {
                    try o.indent();
                    try o.w.print("subgraph \"cluster_{d}\" {{\n", .{index});
                    o.depth += 1;
                    try o.indent();
                    try o.w.writeAll("label=\"");
                    try dotText(o.w, name);
                    try o.w.writeAll("\";\n");
                    o.clusters += 1;
                },
                .mermaid => try o.open("", name),
            }
        }
        fn close(o: *Self) Writer.Error!void {
            o.depth -= 1;
            try o.indent();
            try o.w.writeAll(if (format == .dot) "}\n" else "end\n");
        }
        fn node(o: *Self, index: usize, p: []const u8) Writer.Error!void {
            const label = if (o.labels) p[if (std.mem.findScalarLast(u8, p, '/')) |s| s + 1 else 0..] else p;
            const labelled = label.len != p.len;
            const marked = o.marks.nodes.isSet(index);
            try o.indent();
            switch (format) {
                .dot => {
                    try o.w.writeByte('"');
                    try dotText(o.w, p);
                    try o.w.writeByte('"');
                    if (labelled or marked) {
                        try o.w.writeAll(" [");
                        if (labelled) {
                            try o.w.writeAll("label=\"");
                            try dotText(o.w, label);
                            try o.w.writeAll(if (marked) "\", " else "\"");
                        }
                        if (marked) try o.w.writeAll("color=\"" ++ red ++ "\", fontcolor=\"" ++ red ++ "\", penwidth=2");
                        try o.w.writeByte(']');
                    }
                    try o.w.writeAll(";\n");
                },
                .mermaid => {
                    try o.w.print("n{d}[\"", .{index});
                    try mermaidText(o.w, label);
                    try o.w.writeAll(if (marked) "\"]:::finding\n" else "\"]\n");
                },
            }
        }
        fn edge(o: *Self, index: usize, e: t.Edge, from: usize, to: usize) Writer.Error!void {
            const marked = o.marks.edges.isSet(index);
            switch (format) {
                .dot => {
                    try o.w.writeAll("  \"");
                    try dotText(o.w, e.from);
                    try o.w.writeAll("\" -> \"");
                    try dotText(o.w, e.to);
                    try o.w.writeByte('"');
                    const style: []const u8 = switch (e.kind) {
                        .import => "",
                        .type_only => "style=dashed",
                        .dynamic => "style=dotted",
                        .@"test" => "arrowhead=onormal",
                        .link => "style=dashed, arrowhead=vee",
                        .asset => "style=dotted, arrowhead=odot",
                    };
                    if (style.len > 0 or marked) {
                        try o.w.writeAll(" [");
                        try o.w.writeAll(style);
                        if (marked) try o.w.writeAll(if (style.len > 0) ", color=\"" ++ red ++ "\", penwidth=2" else "color=\"" ++ red ++ "\", penwidth=2");
                        try o.w.writeByte(']');
                    }
                    try o.w.writeAll(";\n");
                },
                .mermaid => try o.w.print("  n{d} {s} n{d}\n", .{ from, switch (e.kind) {
                    .import => "-->",
                    .@"test" => "-->|test|",
                    .type_only => "-.->|type_only|",
                    .dynamic => "-.->|dynamic|",
                    .link => "-.->|link|",
                    .asset => "-.->|asset|",
                }, to }),
            }
        }
    };
}

/// Nodes and edges that findings name, by their place in the graph.
const Marks = struct {
    nodes: std.DynamicBitSetUnmanaged,
    edges: std.DynamicBitSetUnmanaged,

    fn init(gpa: std.mem.Allocator, graph: *const Graph, findings: []const engine.Violation) !Marks {
        const paths = graph.paths();
        const edges = graph.edges();
        var nodes = try std.DynamicBitSetUnmanaged.initEmpty(gpa, paths.len);
        errdefer nodes.deinit(gpa);
        var marked = try std.DynamicBitSetUnmanaged.initEmpty(gpa, edges.len);
        errdefer marked.deinit(gpa);
        for (findings) |f| {
            var named: [5]?[]const u8 = .{ f.path, null, null, null, null };
            if (f.edge) |e| {
                named[1] = e.from;
                named[2] = e.to;
                var i = start(edges, e.from, e.to);
                while (i < edges.len and same(edges[i], e.from, e.to)) : (i += 1) if (edges[i].kind == e.kind) marked.set(i);
            }
            if (f.reference) |r| named[3] = r.from;
            if (f.token) |k| named[3] = k.path;
            if (f.dependency) |d| named[4] = d.manifest;
            for (named) |n| if (n) |p| if (position(paths, p)) |i| nodes.set(i);
            for (f.chain, 0..) |p, c| {
                if (position(paths, p)) |i| nodes.set(i);
                if (c == 0) continue;
                var i = start(edges, f.chain[c - 1], p);
                while (i < edges.len and same(edges[i], f.chain[c - 1], p)) : (i += 1) marked.set(i);
            }
        }
        return .{ .nodes = nodes, .edges = marked };
    }
    fn deinit(m: *Marks, gpa: std.mem.Allocator) void {
        m.nodes.deinit(gpa);
        m.edges.deinit(gpa);
        m.* = undefined;
    }
    fn same(e: t.Edge, from: []const u8, to: []const u8) bool {
        return std.mem.eql(u8, e.from, from) and std.mem.eql(u8, e.to, to);
    }
    /// The first edge from `from` to `to` or after, in the graph's order.
    fn start(edges: []const t.Edge, from: []const u8, to: []const u8) usize {
        const Key = struct { from: []const u8, to: []const u8 };
        return std.sort.lowerBound(t.Edge, edges, Key{ .from = from, .to = to }, struct {
            fn order(key: Key, e: t.Edge) std.math.Order {
                const o = std.mem.order(u8, key.from, e.from);
                return if (o != .eq) o else std.mem.order(u8, key.to, e.to);
            }
        }.order);
    }
};

fn position(paths: []const []const u8, p: []const u8) ?usize {
    const i = std.sort.lowerBound([]const u8, paths, p, struct {
        fn order(key: []const u8, item: []const u8) std.math.Order {
            return std.mem.order(u8, key, item);
        }
    }.order);
    return if (i < paths.len and std.mem.eql(u8, paths[i], p)) i else null;
}

fn firstLayer(layers: []const engine.Layer, p: []const u8) usize {
    for (layers, 0..) |l, i| for (l.patterns) |pattern| if (engine.matches(pattern, p)) return i;
    return layers.len;
}

fn parent(p: []const u8) []const u8 {
    return p[0 .. std.mem.findScalarLast(u8, p, '/') orelse 0];
}

/// `dir` is `open` or lies under it.
fn within(open: []const u8, dir: []const u8) bool {
    return open.len == 0 or (std.mem.startsWith(u8, dir, open) and (dir.len == open.len or dir[open.len] == '/'));
}

/// Inside a DOT quoted string: `"` and `\` escaped, a newline as `\n`,
/// other control bytes and bytes that are not UTF-8 as `\xNN`. Distinct
/// paths stay distinct IDs.
fn dotText(w: *Writer, s: []const u8) Writer.Error!void {
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            0...0x09, 0x0b...0x1f, 0x7f => try w.print("\\x{x:0>2}", .{c}),
            0x20...0x21, 0x23...0x5b, 0x5d...0x7e => try w.writeByte(c),
            else => if (text.sequence(s, i)) |n| {
                try w.writeAll(s[i..][0..n]);
                i += n;
                continue;
            } else try w.print("\\x{x:0>2}", .{c}),
        }
        i += 1;
    }
}

/// Inside a Mermaid quoted label: `"`, `#`, `&`, `<`, `>` and the
/// backtick as entity codes, control bytes as numeric codes and a byte
/// that is not UTF-8 as U+FFFD. Node ids are numbers, so labels need not
/// stay distinct.
fn mermaidText(w: *Writer, s: []const u8) Writer.Error!void {
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        switch (c) {
            '"' => try w.writeAll("#quot;"),
            '#' => try w.writeAll("#35;"),
            '&' => try w.writeAll("#amp;"),
            '<' => try w.writeAll("#lt;"),
            '>' => try w.writeAll("#gt;"),
            '`' => try w.writeAll("#96;"),
            0...0x1f, 0x7f => try w.print("#{d};", .{c}),
            0x20...0x21, 0x24...0x25, 0x27...0x3b, 0x3d, 0x3f...0x5f, 0x61...0x7e => try w.writeByte(c),
            else => if (text.sequence(s, i)) |n| {
                try w.writeAll(s[i..][0..n]);
                i += n;
                continue;
            } else try w.writeAll("#65533;"),
        }
        i += 1;
    }
}
