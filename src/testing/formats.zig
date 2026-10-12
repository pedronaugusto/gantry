//! Syntax checks for the report formats gantry writes, so the tests can say
//! that a golden is a document of its format, not only that it is the bytes
//! last written. DOT and Mermaid are checked as the subset gantry writes
//! them, in UTF-8 with no NUL; JSON as the structure `report.json`
//! documents; SARIF against the vendored 2.1.0 schema (`schema.zig`).
const std = @import("std");
const g = @import("../gantry.zig");
const schema = @import("schema.zig");

pub const Error = error{ InvalidDot, InvalidMermaid, InvalidJson } || schema.Error || std.mem.Allocator.Error;

/// Why the last check on this thread failed.
pub const reason = schema.reason;

fn fail(comptime err: Error, comptime format: []const u8, args: anytype) Error {
    schema.say(format, args);
    return err;
}

/// `text` is UTF-8 and holds no NUL, as the DOT and Mermaid writers promise.
fn utf8(comptime err: Error, comptime format: []const u8, text: []const u8) Error!void {
    var at: usize = 0;
    while (at < text.len) {
        if (text[at] == 0) return fail(err, format ++ ": a NUL at byte {d}", .{at});
        const n = std.unicode.utf8ByteSequenceLength(text[at]) catch return fail(err, format ++ ": not UTF-8 at byte {d}", .{at});
        if (at + n > text.len or !std.unicode.utf8ValidateSlice(text[at..][0..n])) return fail(err, format ++ ": not UTF-8 at byte {d}", .{at});
        at += n;
    }
}

/// A DOT digraph of the statements gantry writes: `ID = ID;`,
/// `node|edge|graph [attrs];`, `ID [attrs];`, `ID -> ID [attrs];` and
/// `subgraph ID { ... }`, braces and brackets balanced. An ID is as
/// Graphviz reads one: a name `[A-Za-z_\x80-\xff][A-Za-z0-9_\x80-\xff]*`
/// that is no keyword (`node`, `edge`, `graph`, `digraph`, `subgraph`,
/// `strict`, in any case), a numeral, or a quoted string on one line.
pub fn dot(text: []const u8) Error!void {
    try utf8(error.InvalidDot, "dot", text);
    var p: Dot = .{ .text = text };
    try p.document();
}

fn keyword(name: []const u8) bool {
    for ([_][]const u8{ "node", "edge", "graph", "digraph", "subgraph", "strict" }) |k| {
        if (std.ascii.eqlIgnoreCase(name, k)) return true;
    }
    return false;
}

fn nameByte(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_' or byte >= 0x80;
}

const Dot = struct {
    text: []const u8,
    at: usize = 0,

    fn document(p: *Dot) Error!void {
        p.space();
        const head = p.name() orelse "";
        if (!std.ascii.eqlIgnoreCase(head, "digraph")) return fail(error.InvalidDot, "dot: starts with '{s}', not digraph", .{head});
        _ = try p.id();
        try p.block();
        p.space();
        if (p.at != p.text.len) return fail(error.InvalidDot, "dot: text after the graph, at byte {d}", .{p.at});
    }

    fn block(p: *Dot) Error!void {
        try p.expect('{');
        while (true) {
            p.space();
            if (p.peek() == '}') {
                p.at += 1;
                return;
            }
            try p.statement();
        }
    }

    fn statement(p: *Dot) Error!void {
        p.space();
        const start = p.at;
        if (p.name()) |head| if (keyword(head)) {
            if (std.ascii.eqlIgnoreCase(head, "subgraph")) {
                _ = try p.id();
                return p.block();
            }
            if (std.ascii.eqlIgnoreCase(head, "digraph") or std.ascii.eqlIgnoreCase(head, "strict")) return fail(error.InvalidDot, "dot: '{s}' heads no statement, at byte {d}", .{ head, start });
            try p.attributes();
            return p.expect(';');
        };
        p.at = start;
        _ = try p.id();
        p.space();
        switch (p.peek()) {
            '=' => {
                p.at += 1;
                _ = try p.id();
            },
            '-' => {
                try p.arrow();
                _ = try p.id();
                p.space();
                if (p.peek() == '[') try p.attributes();
            },
            '[' => try p.attributes(),
            else => {},
        }
        try p.expect(';');
    }

    fn attributes(p: *Dot) Error!void {
        try p.expect('[');
        while (true) {
            _ = try p.id();
            try p.expect('=');
            _ = try p.id();
            p.space();
            switch (p.peek()) {
                ',' => p.at += 1,
                ']' => {
                    p.at += 1;
                    return;
                },
                else => return fail(error.InvalidDot, "dot: an attribute list is not closed, at byte {d}", .{p.at}),
            }
        }
    }

    fn arrow(p: *Dot) Error!void {
        if (!std.mem.startsWith(u8, p.text[p.at..], "->")) return fail(error.InvalidDot, "dot: expected -> at byte {d}", .{p.at});
        p.at += 2;
    }

    fn peek(p: *const Dot) u8 {
        return if (p.at < p.text.len) p.text[p.at] else 0;
    }

    fn space(p: *Dot) void {
        while (p.at < p.text.len and std.ascii.isWhitespace(p.text[p.at])) p.at += 1;
    }

    fn expect(p: *Dot, byte: u8) Error!void {
        p.space();
        if (p.peek() != byte) return fail(error.InvalidDot, "dot: expected '{c}' at byte {d}", .{ byte, p.at });
        p.at += 1;
    }

    /// A name that is no keyword, a numeral, or a quoted string.
    fn id(p: *Dot) Error![]const u8 {
        p.space();
        const start = p.at;
        if (p.name()) |word| {
            if (keyword(word)) return fail(error.InvalidDot, "dot: the keyword '{s}' is no ID, at byte {d}", .{ word, start });
            return word;
        }
        if (p.peek() == '"') return p.quoted();
        return p.numeral();
    }

    /// `[A-Za-z_\x80-\xff][A-Za-z0-9_\x80-\xff]*`, or null with nothing read.
    fn name(p: *Dot) ?[]const u8 {
        const start = p.at;
        while (p.at < p.text.len and (nameByte(p.text[p.at]) or (p.at > start and std.ascii.isDigit(p.text[p.at])))) p.at += 1;
        return if (p.at == start) null else p.text[start..p.at];
    }

    /// `-?(\.[0-9]+|[0-9]+(\.[0-9]*)?)`.
    fn numeral(p: *Dot) Error![]const u8 {
        const start = p.at;
        if (p.peek() == '-') p.at += 1;
        var count = p.digits();
        if (p.peek() == '.') {
            p.at += 1;
            count += p.digits();
        }
        if (count == 0) return fail(error.InvalidDot, "dot: expected an ID at byte {d}", .{start});
        return p.text[start..p.at];
    }

    fn digits(p: *Dot) usize {
        const start = p.at;
        while (p.at < p.text.len and std.ascii.isDigit(p.text[p.at])) p.at += 1;
        return p.at - start;
    }

    fn quoted(p: *Dot) Error![]const u8 {
        const start = p.at;
        p.at += 1;
        while (p.at < p.text.len) : (p.at += 1) switch (p.text[p.at]) {
            '\\' => p.at += 1,
            '"' => {
                p.at += 1;
                return p.text[start..p.at];
            },
            '\n', '\r' => break,
            else => {},
        };
        return fail(error.InvalidDot, "dot: a string from byte {d} is not closed on its line", .{start});
    }
};

/// A Mermaid flowchart of the statements gantry writes, one to a line:
/// `flowchart` and a direction (TB, TD, BT, RL or LR); `classDef name
/// style`; nodes `n<digits>["label"]`, with an optional `:::name` of a
/// declared class; `subgraph name["label"]` closed by `end`; edges between
/// declared nodes, `-->` or `-.->` with an optional `|label|`, at most 500
/// of them (Mermaid's default `maxEdges`); and `linkStyle` over edges that
/// exist. A name is `[A-Za-z_][A-Za-z0-9_]*`, and a subgraph's is never
/// `end`; a label holds no raw quote.
pub fn mermaid(text: []const u8) Error!void {
    try utf8(error.InvalidMermaid, "mermaid", text);
    var lines = std.mem.splitScalar(u8, text, '\n');
    try direction(std.mem.trim(u8, lines.next() orelse "", " "));
    var chart: Chart = .{};
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " ");
        if (line.len != 0) try chart.statement(line);
    }
    if (chart.depth != 0) return fail(error.InvalidMermaid, "mermaid: {d} subgraphs are not ended", .{chart.depth});
    if (chart.styled > chart.edges) return fail(error.InvalidMermaid, "mermaid: linkStyle names edge {d} of {d}", .{ chart.styled - 1, chart.edges });
}

fn direction(head: []const u8) Error!void {
    if (!std.mem.startsWith(u8, head, "flowchart ")) return fail(error.InvalidMermaid, "mermaid: starts with '{s}', not flowchart", .{head});
    const way = head["flowchart ".len..];
    for ([_][]const u8{ "TB", "TD", "BT", "RL", "LR" }) |known| if (std.mem.eql(u8, way, known)) return;
    return fail(error.InvalidMermaid, "mermaid: '{s}' is no direction", .{way});
}

const Chart = struct {
    /// Mermaid's default `maxEdges`, which `report.mermaid` documents.
    const max_edges = 500;

    depth: usize = 0,
    edges: usize = 0,
    /// One past the highest edge a linkStyle names.
    styled: usize = 0,
    nodes: [4096][]const u8 = undefined,
    node_count: usize = 0,
    classes: [16][]const u8 = undefined,
    class_count: usize = 0,

    fn statement(c: *Chart, line: []const u8) Error!void {
        if (std.mem.eql(u8, line, "end")) {
            if (c.depth == 0) return fail(error.InvalidMermaid, "mermaid: end without a subgraph", .{});
            c.depth -= 1;
            return;
        }
        if (std.mem.startsWith(u8, line, "classDef ")) return c.classDef(line["classDef ".len..]);
        if (std.mem.startsWith(u8, line, "subgraph ")) return c.subgraph(line["subgraph ".len..]);
        if (std.mem.startsWith(u8, line, "linkStyle ")) return c.linkStyle(line["linkStyle ".len..]);
        const id = nodeId(line);
        if (id == 0) return fail(error.InvalidMermaid, "mermaid: no statement reads '{s}'", .{line});
        if (id < line.len and line[id] == ' ') return c.edge(line[0..id], line[id + 1 ..]);
        return c.node(line[0..id], line[id..]);
    }

    fn classDef(c: *Chart, rest: []const u8) Error!void {
        const gap = std.mem.findScalar(u8, rest, ' ') orelse return fail(error.InvalidMermaid, "mermaid: a classDef without a style: {s}", .{rest});
        try identifier(rest[0..gap]);
        try style(rest[gap + 1 ..]);
        if (c.class_count == c.classes.len) return fail(error.InvalidMermaid, "mermaid: more than the {d} classes this check holds", .{c.classes.len});
        c.classes[c.class_count] = rest[0..gap];
        c.class_count += 1;
    }

    fn subgraph(c: *Chart, rest: []const u8) Error!void {
        const open = std.mem.findScalar(u8, rest, '[') orelse return fail(error.InvalidMermaid, "mermaid: a subgraph without a label: {s}", .{rest});
        try identifier(rest[0..open]);
        if (std.mem.eql(u8, rest[0..open], "end")) return fail(error.InvalidMermaid, "mermaid: a subgraph named end", .{});
        const after = try label(rest[open..]);
        if (after.len != 0) return fail(error.InvalidMermaid, "mermaid: text after a subgraph's label: {s}", .{after});
        c.depth += 1;
    }

    /// `linkStyle 1,3 style`: edge indexes, then a style.
    fn linkStyle(c: *Chart, rest: []const u8) Error!void {
        const gap = std.mem.findScalar(u8, rest, ' ') orelse return fail(error.InvalidMermaid, "mermaid: a linkStyle without a style: {s}", .{rest});
        var indexes = std.mem.splitScalar(u8, rest[0..gap], ',');
        while (indexes.next()) |index| {
            for (index) |b| if (!std.ascii.isDigit(b)) return fail(error.InvalidMermaid, "mermaid: '{s}' is no edge index", .{index});
            const n = std.fmt.parseInt(usize, index, 10) catch return fail(error.InvalidMermaid, "mermaid: '{s}' is no edge index", .{index});
            c.styled = @max(c.styled, n +| 1);
        }
        try style(rest[gap + 1 ..]);
    }

    fn node(c: *Chart, id: []const u8, rest: []const u8) Error!void {
        const after = try label(rest);
        if (after.len != 0) {
            if (!std.mem.startsWith(u8, after, ":::")) return fail(error.InvalidMermaid, "mermaid: text after a node's label: {s}", .{after});
            if (!declared(c.classes[0..c.class_count], after[3..])) return fail(error.InvalidMermaid, "mermaid: no classDef declares '{s}'", .{after[3..]});
        }
        if (c.node_count == c.nodes.len) return fail(error.InvalidMermaid, "mermaid: more than the {d} nodes this check holds", .{c.nodes.len});
        c.nodes[c.node_count] = id;
        c.node_count += 1;
    }

    /// `rest` follows the source and its space: an arrow, an optional
    /// `|label|`, a space and the target.
    fn edge(c: *Chart, from: []const u8, rest: []const u8) Error!void {
        const arrow: []const u8 = if (std.mem.startsWith(u8, rest, "-->")) "-->" else if (std.mem.startsWith(u8, rest, "-.->")) "-.->" else return fail(error.InvalidMermaid, "mermaid: no arrow begins '{s}'", .{rest});
        var after = rest[arrow.len..];
        if (std.mem.startsWith(u8, after, "|")) {
            const close = std.mem.findScalarPos(u8, after, 1, '|') orelse return fail(error.InvalidMermaid, "mermaid: an edge label is not closed: {s}", .{rest});
            const text = after[1..close];
            if (text.len == 0 or std.mem.findScalar(u8, text, '"') != null) return fail(error.InvalidMermaid, "mermaid: an edge label is empty or holds a quote: {s}", .{rest});
            after = after[close + 1 ..];
        }
        if (!std.mem.startsWith(u8, after, " ")) return fail(error.InvalidMermaid, "mermaid: an edge without a target: {s}", .{rest});
        const to = after[1..];
        if (to.len == 0 or nodeId(to) != to.len) return fail(error.InvalidMermaid, "mermaid: '{s}' is no node id", .{to});
        for ([_][]const u8{ from, to }) |end| {
            if (!declared(c.nodes[0..c.node_count], end)) return fail(error.InvalidMermaid, "mermaid: an edge names '{s}', which no node declares", .{end});
        }
        if (c.edges == max_edges) return fail(error.InvalidMermaid, "mermaid: more than {d} edges, Mermaid's default maxEdges", .{max_edges});
        c.edges += 1;
    }
};

/// The length of the `n<digits>` node id `line` starts with, or 0.
fn nodeId(line: []const u8) usize {
    if (line.len < 2 or line[0] != 'n') return 0;
    var end: usize = 1;
    while (end < line.len and std.ascii.isDigit(line[end])) end += 1;
    return if (end == 1) 0 else end;
}

fn declared(names: []const []const u8, name: []const u8) bool {
    for (names) |known| if (std.mem.eql(u8, known, name)) return true;
    return false;
}

/// `[A-Za-z_][A-Za-z0-9_]*`.
fn identifier(name: []const u8) Error!void {
    for (name, 0..) |b, i| {
        if (!(std.ascii.isAlphabetic(b) or b == '_' or (i > 0 and std.ascii.isDigit(b)))) return fail(error.InvalidMermaid, "mermaid: '{s}' is no name", .{name});
    }
    if (name.len == 0) return fail(error.InvalidMermaid, "mermaid: an empty name", .{});
}

/// `property:value` pairs joined by commas, with no space or `;` in them.
fn style(text: []const u8) Error!void {
    var pairs = std.mem.splitScalar(u8, text, ',');
    while (pairs.next()) |pair| {
        const colon = std.mem.findScalar(u8, pair, ':') orelse return fail(error.InvalidMermaid, "mermaid: '{s}' is no style property", .{pair});
        if (colon == 0 or colon + 1 == pair.len) return fail(error.InvalidMermaid, "mermaid: '{s}' is no style property", .{pair});
        for (pair[0..colon]) |b| if (!std.ascii.isAlphabetic(b) and b != '-') return fail(error.InvalidMermaid, "mermaid: '{s}' is no style property", .{pair});
        for (pair[colon + 1 ..]) |b| if (b == ' ' or b == ';') return fail(error.InvalidMermaid, "mermaid: '{s}' is no style property", .{pair});
    }
}

/// `["text"]` at the front of `s` with the text holding no bare quote, and
/// what follows it.
fn label(s: []const u8) Error![]const u8 {
    if (!std.mem.startsWith(u8, s, "[\"")) return fail(error.InvalidMermaid, "mermaid: a label is not quoted: {s}", .{s});
    const close = std.mem.findPos(u8, s, 2, "\"]") orelse return fail(error.InvalidMermaid, "mermaid: a label is not closed: {s}", .{s});
    if (std.mem.findScalar(u8, s[2..close], '"') != null) return fail(error.InvalidMermaid, "mermaid: a label holds a raw quote: {s}", .{s});
    return s[close + 2 ..];
}

/// The structure `report.json` documents: format, version, nodes, edges
/// between the nodes, and findings that name a rule, a reason and the
/// documented fields, with no key it does not document.
pub fn json(gpa: std.mem.Allocator, text: []const u8) Error!void {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, text, .{}) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => fail(error.InvalidJson, "json: {t}", .{err}),
    };
    defer parsed.deinit();
    const root = try object(parsed.value, "the report", &.{ "format", "version", "nodes", "edges", "findings" });
    if (!std.mem.eql(u8, try string(root, "format"), "gantry")) return fail(error.InvalidJson, "json: format is not gantry", .{});
    const version = root.get("version") orelse return fail(error.InvalidJson, "json: no version", .{});
    if (version != .integer or version.integer != 1) return fail(error.InvalidJson, "json: version is not 1", .{});
    const nodes = try array(root, "nodes");
    for (nodes) |node| _ = try string(try object(node, "a node", &.{"path"}), "path");
    for (try array(root, "edges")) |edge_value| try edge(edge_value, nodes);
    for (try array(root, "findings")) |value| try finding(value, nodes);
}

fn finding(value: std.json.Value, nodes: []const std.json.Value) Error!void {
    const fields = try object(value, "a finding", &.{ "rule", "reason", "edge", "reference", "token", "path", "dependency", "package", "chain" });
    _ = try string(fields, "rule");
    try tag(g.rules.Violation.Reason, fields, "reason");
    if (fields.get("edge")) |e| try edge(e, nodes);
    if (fields.get("reference")) |r| try reference(r);
    if (fields.get("token")) |k| try token(k);
    if (fields.contains("path")) _ = try string(fields, "path");
    if (fields.get("dependency")) |d| try dependency(d);
    if (fields.contains("package")) _ = try string(fields, "package");
    if (fields.get("chain")) |chain| {
        if (chain != .array) return fail(error.InvalidJson, "json: a chain is not an array", .{});
        for (chain.array.items) |step| {
            if (step != .string) return fail(error.InvalidJson, "json: a chain holds a non-path", .{});
            if (!named(nodes, step.string)) return fail(error.InvalidJson, "json: a chain names '{s}', no node", .{step.string});
        }
    }
}

fn reference(value: std.json.Value) Error!void {
    const fields = try object(value, "a reference", &.{ "from", "name", "offset", "member", "resolved", "kind" });
    _ = try string(fields, "from");
    _ = try string(fields, "name");
    try natural(fields, "offset", 0);
    if (fields.contains("member")) _ = try string(fields, "member");
    const resolved = fields.get("resolved") orelse return fail(error.InvalidJson, "json: no 'resolved'", .{});
    if (resolved != .bool) return fail(error.InvalidJson, "json: 'resolved' is not a boolean", .{});
    try tag(g.Kind, fields, "kind");
}

fn token(value: std.json.Value) Error!void {
    const fields = try object(value, "a token", &.{ "path", "kind", "text", "offset", "line", "column" });
    _ = try string(fields, "path");
    try tag(g.Token.Kind, fields, "kind");
    _ = try string(fields, "text");
    try natural(fields, "offset", 0);
    try natural(fields, "line", 1);
    try natural(fields, "column", 1);
}

fn dependency(value: std.json.Value) Error!void {
    const fields = try object(value, "a dependency", &.{ "manifest", "name", "requirement", "source", "group", "origin", "scope" });
    for ([_][]const u8{ "manifest", "name", "requirement", "source", "group" }) |name| _ = try string(fields, name);
    try tag(g.Dependency.Origin, fields, "origin");
    try tag(g.Dependency.Scope, fields, "scope");
}

fn edge(value: std.json.Value, nodes: []const std.json.Value) Error!void {
    const fields = try object(value, "an edge", &.{ "from", "to", "kind", "count" });
    for ([_][]const u8{ "from", "to" }) |end| {
        const path = try string(fields, end);
        if (!named(nodes, path)) return fail(error.InvalidJson, "json: an edge ends at '{s}', no node", .{path});
    }
    try tag(g.Kind, fields, "kind");
    try natural(fields, "count", 1);
}

/// A node has `path`. `json` checked every node as an object with a string
/// `path` before it reads an edge or a finding, so the `.?` holds.
fn named(nodes: []const std.json.Value, path: []const u8) bool {
    for (nodes) |node| if (std.mem.eql(u8, node.object.get("path").?.string, path)) return true;
    return false;
}

/// `value` is an object whose keys are all in `keys`.
fn object(value: std.json.Value, what: []const u8, keys: []const []const u8) Error!std.json.ObjectMap {
    if (value != .object) return fail(error.InvalidJson, "json: {s} is not an object", .{what});
    for (value.object.keys()) |key| {
        for (keys) |known| {
            if (std.mem.eql(u8, key, known)) break;
        } else return fail(error.InvalidJson, "json: {s} has '{s}', which the report does not document", .{ what, key });
    }
    return value.object;
}

fn string(fields: std.json.ObjectMap, name: []const u8) Error![]const u8 {
    const value = fields.get(name) orelse return fail(error.InvalidJson, "json: no '{s}'", .{name});
    if (value != .string) return fail(error.InvalidJson, "json: '{s}' is not a string", .{name});
    return value.string;
}

/// The string `name` spells a field of `Enum`.
fn tag(comptime Enum: type, fields: std.json.ObjectMap, name: []const u8) Error!void {
    const value = try string(fields, name);
    if (std.meta.stringToEnum(Enum, value) == null) return fail(error.InvalidJson, "json: '{s}' is no {s}", .{ value, name });
}

/// An integer at least `least`.
fn natural(fields: std.json.ObjectMap, name: []const u8, least: i64) Error!void {
    const value = fields.get(name) orelse return fail(error.InvalidJson, "json: no '{s}'", .{name});
    if (value != .integer or value.integer < least) return fail(error.InvalidJson, "json: '{s}' is not an integer of at least {d}", .{ name, least });
}

fn array(fields: std.json.ObjectMap, name: []const u8) Error![]const std.json.Value {
    const value = fields.get(name) orelse return fail(error.InvalidJson, "json: no '{s}'", .{name});
    if (value != .array) return fail(error.InvalidJson, "json: '{s}' is not an array", .{name});
    return value.array.items;
}

/// SARIF 2.1.0: `text` against the schema the OASIS technical committee
/// publishes, which `sarif_schema` holds.
pub fn sarif(gpa: std.mem.Allocator, text: []const u8, sarif_schema: []const u8) Error!void {
    return schema.validate(gpa, sarif_schema, text);
}

const testing = std.testing;

fn dotRefuses(texts: []const []const u8) !void {
    for (texts) |text| {
        errdefer std.debug.print("dot accepted: {s}\n", .{text});
        try testing.expectError(error.InvalidDot, dot(text));
    }
}

fn mermaidRefuses(texts: []const []const u8) !void {
    for (texts) |text| {
        errdefer std.debug.print("mermaid accepted: {s}\n", .{text});
        try testing.expectError(error.InvalidMermaid, mermaid(text));
    }
}

/// Each finding in a report of nodes `a` and `b` and an edge between them.
fn jsonFindings(findings: []const []const u8) ![2]usize {
    var counts: [2]usize = .{ 0, 0 };
    for (findings) |f| {
        const text = try testing.allocator.print("{{\"format\":\"gantry\",\"version\":1,\"nodes\":[{{\"path\":\"a\"}},{{\"path\":\"b\"}}],\"edges\":[{{\"from\":\"a\",\"to\":\"b\",\"kind\":\"import\",\"count\":1}}],\"findings\":[{s}]}}", .{f});
        defer testing.allocator.free(text);
        if (json(testing.allocator, text)) counts[0] += 1 else |err| switch (err) {
            error.InvalidJson => counts[1] += 1,
            else => return err,
        }
    }
    return counts;
}

fn jsonRefuses(findings: []const []const u8) !void {
    for (findings) |f| {
        errdefer std.debug.print("json accepted: {s}\n", .{f});
        try testing.expectEqual([2]usize{ 0, 1 }, try jsonFindings(&.{f}));
    }
}

test "dot accepts the subset gantry writes and refuses text outside it" {
    try dot("digraph \"g\" {\n  rankdir=LR;\n  node [shape=box, style=rounded];\n  \"a\" [label=\"x\"];\n  subgraph \"c\" {\n    \"b\";\n  }\n  \"a\" -> \"b\" [color=\"#cc0000\", penwidth=2];\n}\n");
    try dotRefuses(&.{
        "graph g {}",
        "digraph \"g\" {\n  \"a\"\n}\n",
        "digraph \"g\" {\n  \"a\" -> ;\n}\n",
        "digraph \"g\" {\n  \"a [label=\"x\"];\n}\n",
        "digraph \"g\" {\n  \"a\" [label=\"x\";\n}\n",
        "digraph \"g\" {\n  \"a\";\n",
        "digraph \"g\" {\n  \"a\";\n}\n}\n",
    });
}

test "dot refuses a keyword as an ID unless it heads an attribute statement" {
    try dot("digraph \"g\" {\n  graph [rankdir=LR];\n  edge [style=dashed];\n  \"node\" -> \"graph\";\n}\n");
    try dotRefuses(&.{
        "digraph node {\n}\n",
        "digraph \"g\" {\n  node;\n}\n",
        "digraph \"g\" {\n  strict;\n}\n",
        "digraph \"g\" {\n  \"a\" -> edge;\n}\n",
        "digraph \"g\" {\n  \"a\" [label=Graph];\n}\n",
        "digraph \"g\" {\n  subgraph digraph {\n  }\n}\n",
        "digraph \"g\" {\n  SubGraph = \"x\";\n}\n",
    });
}

test "dot reads an ID as Graphviz does: a name, a numeral or a quoted string" {
    try dot("digraph g {\n  a_1 [w=-1.5, x=.5, y=2., z=_\xc3\xbc9, q=\"\\\"\"];\n  \xc3\xbc -> a_1;\n}\n");
    try dotRefuses(&.{
        "digraph \"g\" {\n  1a;\n}\n",
        "digraph \"g\" {\n  a.b;\n}\n",
        "digraph \"g\" {\n  \"a\" [w=1.2.3];\n}\n",
        "digraph \"g\" {\n  \"a\" [w=.];\n}\n",
        "digraph \"g\" {\n  \"a\" [w=2px];\n}\n",
    });
}

test "dot refuses text that is not UTF-8 or holds a NUL" {
    try dot("digraph \"g\" {\n  \"\xc3\xbc\" -> \"\\xff\";\n}\n");
    try dotRefuses(&.{
        "digraph \"g\" {\n  \"a\xffb\";\n}\n",
        "digraph \"g\" {\n  \"a\x00b\";\n}\n",
        "digraph \"g\" {\n  \"a\xed\xa0\x80b\";\n}\n",
        "digraph \"g\" {\n  \"a\xc3\";\n}\n",
        "digraph \"g\" {\n  a\xffb;\n}\n",
    });
}

test "mermaid accepts the subset gantry writes and refuses a broken chart" {
    try mermaid("flowchart LR\n  classDef finding stroke:#cc0000\n  n0[\"a\"]\n  subgraph d0[\"d\"]\n    n1[\"b\"]:::finding\n  end\n  n0 -.->|link| n1\n  n1 --> n0\n  linkStyle 1 stroke:#cc0000\n");
    try mermaidRefuses(&.{
        "graph LR\n  n0[\"a\"]\n",
        "flowchart LR\n  n0[\"a\"]\n  n0 --> n1\n",
        "flowchart LR\n  subgraph d0[\"d\"]\n    n0[\"a\"]\n",
        "flowchart LR\n  n0[\"a\"q\"]\n",
        "flowchart LR\n  n0[\"a\"]\n  n0 --> n0\n  linkStyle 3 stroke:#cc0000\n",
        "flowchart LR\n  end\n",
    });
}

test "mermaid refuses text that is not UTF-8 or holds a NUL" {
    try mermaid("flowchart LR\n  n0[\"\xc3\xbcn\xc3\xaf\"]\n");
    try mermaidRefuses(&.{
        "flowchart LR\n  n0[\"a\xffb\"]\n",
        "flowchart LR\n  n0[\"a\x00b\"]\n",
        "flowchart LR\n  n0[\"a\xed\xa0\x80b\"]\n",
    });
}

test "mermaid takes the directions TB, TD, BT, RL and LR" {
    for ([_][]const u8{ "TB", "TD", "BT", "RL", "LR" }) |way| {
        var buffer: [32]u8 = undefined;
        try mermaid(try std.mem.print(&buffer, "flowchart {s}\n  n0[\"a\"]\n", .{way}));
    }
    try mermaidRefuses(&.{ "flowchart XY\n", "flowchart lr\n", "flowchart LR TB\n", "flowchart \n" });
}

test "mermaid node ids are n and digits" {
    try mermaid("flowchart LR\n  n0[\"a\"]\n  n12[\"b\"]\n  n0 --> n12\n");
    try mermaidRefuses(&.{
        "flowchart LR\n  a0[\"a\"]\n",
        "flowchart LR\n  n[\"a\"]\n",
        "flowchart LR\n  n1a[\"a\"]\n",
        "flowchart LR\n  0[\"a\"]\n",
    });
}

test "mermaid subgraphs have a name that is not end, and nothing after the label" {
    try mermaid("flowchart LR\n  subgraph d0[\"x\"]\n    subgraph End[\"y\"]\n    end\n  end\n");
    try mermaidRefuses(&.{
        "flowchart LR\n  subgraph end[\"x\"]\n  end\n",
        "flowchart LR\n  subgraph d0[\"x\"] extra\n  end\n",
        "flowchart LR\n  subgraph d0[\"x\"]:::finding\n  end\n",
        "flowchart LR\n  subgraph 0d[\"x\"]\n  end\n",
        "flowchart LR\n  subgraph [\"x\"]\n  end\n",
        "flowchart LR\n  subgraph d-0[\"x\"]\n  end\n",
    });
}

test "mermaid edge labels are text between bars with no quote" {
    try mermaid("flowchart LR\n  n0[\"a\"]\n  n0 -->|a b| n0\n  n0 -.->|x| n0\n");
    try mermaidRefuses(&.{
        "flowchart LR\n  n0[\"a\"]\n  n0 -->|a\"b| n0\n",
        "flowchart LR\n  n0[\"a\"]\n  n0 -->|a|b| n0\n",
        "flowchart LR\n  n0[\"a\"]\n  n0 -->|| n0\n",
        "flowchart LR\n  n0[\"a\"]\n  n0 -->|a n0\n",
    });
}

test "mermaid classDef takes a name and a style" {
    try mermaid("flowchart LR\n  classDef hot_1 stroke:#c00,stroke-width:2px\n");
    try mermaidRefuses(&.{
        "flowchart LR\n  classDef 1hot stroke:#c00\n",
        "flowchart LR\n  classDef h-t stroke:#c00\n",
        "flowchart LR\n  classDef hot\n",
        "flowchart LR\n  classDef hot stroke\n",
        "flowchart LR\n  classDef hot stroke:#c00;n0\n",
        "flowchart LR\n  classDef hot stroke:#c00,,color:#c00\n",
        "flowchart LR\n  classDef hot stroke: #c00\n",
        "flowchart LR\n  classDef hot :#c00\n",
    });
}

test "mermaid takes a class on a node only once a classDef declares it" {
    try mermaid("flowchart LR\n  classDef hot stroke:#c00\n  n0[\"a\"]:::hot\n");
    try mermaidRefuses(&.{
        "flowchart LR\n  n0[\"a\"]:::hot\n",
        "flowchart LR\n  classDef hot stroke:#c00\n  n0[\"a\"]:::cold\n",
        "flowchart LR\n  classDef hot stroke:#c00\n  n0[\"a\"]:::\n",
    });
}

test "mermaid linkStyle takes edge indexes joined by commas, then a style" {
    const head = "flowchart LR\n  n0[\"a\"]\n  n0 --> n0\n  n0 --> n0\n  ";
    try mermaid(head ++ "linkStyle 0,1 stroke:#c00\n");
    try mermaidRefuses(&.{
        head ++ "linkStyle 0,,1 stroke:#c00\n",
        head ++ "linkStyle ,0 stroke:#c00\n",
        head ++ "linkStyle 0, stroke:#c00\n",
        head ++ "linkStyle +0 stroke:#c00\n",
        head ++ "linkStyle 0\n",
        head ++ "linkStyle 0 stroke\n",
        head ++ "linkStyle 0 1 stroke:#c00\n",
    });
}

test "mermaid refuses more edges than Mermaid's default maxEdges" {
    var buffer: [8 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try w.writeAll("flowchart LR\n  n0[\"a\"]\n");
    for (0..500) |_| try w.writeAll("  n0 --> n0\n");
    try mermaid(w.buffered());
    try w.writeAll("  n0 --> n0\n");
    try mermaidRefuses(&.{w.buffered()});
}

test "mermaid says why a chart past the nodes it holds is refused" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try out.writer.writeAll("flowchart LR\n");
    for (0..4097) |i| try out.writer.print("  n{d}[\"a\"]\n", .{i});
    schema.say("stale", .{});
    try mermaidRefuses(&.{out.written()});
    try testing.expect(std.mem.find(u8, reason(), "4096 nodes") != null);
}

test "json holds the structure the report documents" {
    const a = testing.allocator;
    try json(a, "{\"format\":\"gantry\",\"version\":1,\"nodes\":[{\"path\":\"a\"},{\"path\":\"b\"}],\"edges\":[{\"from\":\"a\",\"to\":\"b\",\"kind\":\"import\",\"count\":1}],\"findings\":[{\"rule\":\"r\",\"reason\":\"forbidden\",\"chain\":[\"a\",\"b\"]}]}");
    try testing.expectError(error.InvalidJson, json(a, "{\"format\":\"gantry\",\"version\":2,\"nodes\":[],\"edges\":[],\"findings\":[]}"));
    try testing.expectError(error.InvalidJson, json(a, "{\"format\":\"gantry\",\"version\":1,\"nodes\":[{\"path\":\"a\"}],\"edges\":[{\"from\":\"a\",\"to\":\"z\",\"kind\":\"import\",\"count\":1}],\"findings\":[]}"));
    try testing.expectError(error.InvalidJson, json(a, "{\"format\":\"gantry\",\"version\":1,\"nodes\":[{\"path\":\"a\"}],\"edges\":[{\"from\":\"a\",\"to\":\"a\",\"kind\":\"sideways\",\"count\":1}],\"findings\":[]}"));
    try testing.expectError(error.InvalidJson, json(a, "{\"format\":\"gantry\",\"version\":1,\"nodes\":[{\"path\":\"a\"}],\"edges\":[],\"findings\":[{\"rule\":\"r\"}]}"));
    try testing.expectError(error.InvalidJson, json(a, "{\"format\":\"gantry\""));
}

test "json requires findings, which the writer always writes" {
    const a = testing.allocator;
    try json(a, "{\"format\":\"gantry\",\"version\":1,\"nodes\":[],\"edges\":[],\"findings\":[]}");
    try testing.expectError(error.InvalidJson, json(a, "{\"format\":\"gantry\",\"version\":1,\"nodes\":[],\"edges\":[]}"));
}

test "json reasons are the reasons a Violation has" {
    inline for (@typeInfo(g.rules.Violation.Reason).@"enum".field_names) |name| {
        try testing.expectEqual([2]usize{ 1, 0 }, try jsonFindings(&.{"{\"rule\":\"r\",\"reason\":\"" ++ name ++ "\"}"}));
    }
    try jsonRefuses(&.{ "{\"rule\":\"r\",\"reason\":\"sideways\"}", "{\"rule\":\"r\",\"reason\":1}" });
}

test "json findings carry the fields the report documents, in their shapes" {
    const with_reference = "\"reference\":{\"from\":\"a\",\"name\":\"x\",\"offset\":0,\"member\":\"m\",\"resolved\":true,\"kind\":\"import\"}";
    const with_token = "\"token\":{\"path\":\"a\",\"kind\":\"identifier\",\"text\":\"t\",\"offset\":3,\"line\":1,\"column\":4}";
    const with_dependency = "\"dependency\":{\"manifest\":\"m\",\"name\":\"n\",\"requirement\":\"\",\"source\":\"\",\"group\":\"dependencies\",\"origin\":\"registry\",\"scope\":\"runtime\"}";
    try testing.expectEqual([2]usize{ 1, 0 }, try jsonFindings(&.{"{\"rule\":\"r\",\"reason\":\"reference\",\"edge\":{\"from\":\"a\",\"to\":\"b\",\"kind\":\"import\",\"count\":1}," ++ with_reference ++ "," ++ with_token ++ ",\"path\":\"elsewhere\"," ++ with_dependency ++ ",\"package\":\"p\",\"chain\":[\"a\",\"b\"]}"}));
    try jsonRefuses(&.{
        "{\"rule\":\"r\",\"reason\":\"missing\",\"path\":1}",
        "{\"rule\":\"r\",\"reason\":\"undeclared\",\"package\":true}",
        "{\"rule\":\"r\",\"reason\":\"missing\",\"note\":\"x\"}",
        "{\"rule\":\"r\",\"reason\":\"reference\",\"reference\":1}",
        "{\"rule\":\"r\",\"reason\":\"reference\",\"reference\":{\"from\":\"a\",\"name\":\"x\",\"offset\":0,\"kind\":\"import\"}}",
        "{\"rule\":\"r\",\"reason\":\"reference\",\"reference\":{\"from\":\"a\",\"name\":\"x\",\"offset\":0,\"resolved\":\"yes\",\"kind\":\"import\"}}",
        "{\"rule\":\"r\",\"reason\":\"reference\",\"reference\":{\"from\":\"a\",\"name\":\"x\",\"offset\":-1,\"resolved\":true,\"kind\":\"import\"}}",
        "{\"rule\":\"r\",\"reason\":\"reference\",\"reference\":{\"from\":\"a\",\"name\":\"x\",\"offset\":0,\"resolved\":true,\"kind\":\"sideways\"}}",
        "{\"rule\":\"r\",\"reason\":\"reference\",\"reference\":{\"from\":\"a\",\"name\":\"x\",\"offset\":0,\"resolved\":true,\"kind\":\"import\",\"extra\":1}}",
        "{\"rule\":\"r\",\"reason\":\"token\",\"token\":{\"path\":\"a\",\"kind\":\"word\",\"text\":\"t\",\"offset\":3,\"line\":1,\"column\":4}}",
        "{\"rule\":\"r\",\"reason\":\"token\",\"token\":{\"path\":\"a\",\"kind\":\"string\",\"text\":\"t\",\"offset\":3,\"line\":0,\"column\":4}}",
        "{\"rule\":\"r\",\"reason\":\"token\",\"token\":{\"path\":\"a\",\"kind\":\"string\",\"offset\":3,\"line\":1,\"column\":4}}",
        "{\"rule\":\"r\",\"reason\":\"unused\",\"dependency\":{\"manifest\":\"m\",\"name\":\"n\",\"requirement\":\"\",\"source\":\"\",\"group\":\"dependencies\",\"origin\":\"elsewhere\",\"scope\":\"runtime\"}}",
        "{\"rule\":\"r\",\"reason\":\"unused\",\"dependency\":{\"manifest\":\"m\",\"name\":\"n\",\"requirement\":\"\",\"source\":\"\",\"group\":\"dependencies\",\"origin\":\"local\",\"scope\":\"always\"}}",
        "{\"rule\":\"r\",\"reason\":\"unused\",\"dependency\":{\"manifest\":\"m\",\"name\":\"n\",\"requirement\":\"\",\"source\":\"\",\"origin\":\"local\",\"scope\":\"runtime\"}}",
    });
}

test "json chains name only nodes that exist" {
    try testing.expectEqual([2]usize{ 1, 0 }, try jsonFindings(&.{"{\"rule\":\"r\",\"reason\":\"forbidden\",\"chain\":[\"a\",\"b\"]}"}));
    try jsonRefuses(&.{"{\"rule\":\"r\",\"reason\":\"forbidden\",\"chain\":[\"a\",\"z\"]}"});
}
