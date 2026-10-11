//! Syntax checks for the report formats gantry writes, so the tests can say
//! that a golden is a document of its format, not only that it is the bytes
//! last written. DOT and Mermaid are checked as the subset gantry writes
//! them; JSON as the structure `report.json` documents; SARIF against the
//! vendored 2.1.0 schema (`schema.zig`).
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

/// A DOT digraph of statements: `ID = ID;`, `node|edge|graph [attrs];`,
/// `ID [attrs];`, `ID -> ID [attrs];` and `subgraph ID { ... }`, with an ID
/// a quoted string or a bare word, braces and brackets balanced.
pub fn dot(text: []const u8) Error!void {
    var p: Dot = .{ .text = text };
    try p.document();
}

const Dot = struct {
    text: []const u8,
    at: usize = 0,

    fn document(p: *Dot) Error!void {
        const head = try p.word();
        if (!std.mem.eql(u8, head, "digraph")) return fail(error.InvalidDot, "dot: starts with '{s}', not digraph", .{head});
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
        const first = try p.id();
        if (std.mem.eql(u8, first, "subgraph")) {
            _ = try p.id();
            return p.block();
        }
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

    fn word(p: *Dot) Error![]const u8 {
        p.space();
        const start = p.at;
        while (p.at < p.text.len and (std.ascii.isAlphanumeric(p.text[p.at]) or p.text[p.at] == '_' or p.text[p.at] == '.' or p.text[p.at] >= 0x80)) p.at += 1;
        if (p.at == start) return fail(error.InvalidDot, "dot: expected a word at byte {d}", .{start});
        return p.text[start..p.at];
    }

    /// A quoted string, or a bare word.
    fn id(p: *Dot) Error![]const u8 {
        p.space();
        if (p.peek() != '"') return p.word();
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

/// A Mermaid flowchart: the `flowchart` line, `classDef`, nodes
/// `id["label"]` with an optional `:::class`, `subgraph id["label"]` closed
/// by `end`, edges between declared nodes (`-->`, `-.->`, each with an
/// optional `|label|`), and `linkStyle` over edges that exist.
pub fn mermaid(text: []const u8) Error!void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    const head = std.mem.trim(u8, lines.next() orelse "", " ");
    if (!std.mem.startsWith(u8, head, "flowchart ")) return fail(error.InvalidMermaid, "mermaid: starts with '{s}', not flowchart", .{head});
    var depth: usize = 0;
    var edges: usize = 0;
    var ids: [4096][]const u8 = undefined;
    var count: usize = 0;
    var last_style: usize = 0;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " ");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "classDef ")) continue;
        if (std.mem.eql(u8, line, "end")) {
            if (depth == 0) return fail(error.InvalidMermaid, "mermaid: end without a subgraph", .{});
            depth -= 1;
            continue;
        }
        if (std.mem.startsWith(u8, line, "subgraph ")) {
            _ = try label(line["subgraph ".len..]);
            depth += 1;
            continue;
        }
        if (std.mem.startsWith(u8, line, "linkStyle ")) {
            var indexes = std.mem.tokenizeAny(u8, line["linkStyle ".len..], ", ");
            while (indexes.next()) |index| {
                const n = std.fmt.parseInt(usize, index, 10) catch break;
                last_style = @max(last_style, n + 1);
            }
            continue;
        }
        if (std.mem.find(u8, line, "-->") != null or std.mem.find(u8, line, "-.->") != null) {
            var parts = std.mem.tokenizeScalar(u8, line, ' ');
            const from = parts.next() orelse return fail(error.InvalidMermaid, "mermaid: an edge without a source: {s}", .{line});
            const arrow = parts.next() orelse return fail(error.InvalidMermaid, "mermaid: an edge without an arrow: {s}", .{line});
            const to = parts.next() orelse return fail(error.InvalidMermaid, "mermaid: an edge without a target: {s}", .{line});
            if (parts.next() != null) return fail(error.InvalidMermaid, "mermaid: an edge with more than two ends: {s}", .{line});
            const bare = if (std.mem.find(u8, arrow, "|")) |bar| arrow[0..bar] else arrow;
            if (!std.mem.eql(u8, bare, "-->") and !std.mem.eql(u8, bare, "-.->")) return fail(error.InvalidMermaid, "mermaid: '{s}' is no arrow", .{arrow});
            if (std.mem.find(u8, arrow, "|") != null and (arrow[bare.len] != '|' or arrow[arrow.len - 1] != '|' or arrow.len < bare.len + 3)) return fail(error.InvalidMermaid, "mermaid: an edge label is not closed: {s}", .{arrow});
            for ([_][]const u8{ from, to }) |end| {
                var declared = false;
                for (ids[0..count]) |id| declared = declared or std.mem.eql(u8, id, end);
                if (!declared) return fail(error.InvalidMermaid, "mermaid: an edge names '{s}', which no node declares", .{end});
            }
            edges += 1;
            continue;
        }
        const open = std.mem.findScalar(u8, line, '[') orelse return fail(error.InvalidMermaid, "mermaid: no statement reads '{s}'", .{line});
        const name = line[0..open];
        if (name.len == 0 or !std.ascii.isAlphanumeric(name[0])) return fail(error.InvalidMermaid, "mermaid: a node without an id: {s}", .{line});
        const rest = try label(line[open..]);
        if (rest.len != 0 and !std.mem.startsWith(u8, rest, ":::")) return fail(error.InvalidMermaid, "mermaid: text after a node's label: {s}", .{rest});
        if (!std.mem.startsWith(u8, line, "subgraph ")) {
            if (count == ids.len) return error.InvalidMermaid;
            ids[count] = name;
            count += 1;
        }
    }
    if (depth != 0) return fail(error.InvalidMermaid, "mermaid: {d} subgraphs are not ended", .{depth});
    if (last_style > edges) return fail(error.InvalidMermaid, "mermaid: linkStyle names edge {d} of {d}", .{ last_style - 1, edges });
}

/// `["text"]` at the front of `s` with the text holding no bare quote, and
/// what follows it.
fn label(s: []const u8) Error![]const u8 {
    const open = std.mem.findScalar(u8, s, '[') orelse return fail(error.InvalidMermaid, "mermaid: no label in '{s}'", .{s});
    if (!std.mem.startsWith(u8, s[open..], "[\"")) return fail(error.InvalidMermaid, "mermaid: a label is not quoted: {s}", .{s});
    const close = std.mem.findPos(u8, s, open + 2, "\"]") orelse return fail(error.InvalidMermaid, "mermaid: a label is not closed: {s}", .{s});
    const text = s[open + 2 .. close];
    if (std.mem.findScalar(u8, text, '"') != null or std.mem.findScalar(u8, text, '\n') != null) return fail(error.InvalidMermaid, "mermaid: a label holds a raw quote or newline: {s}", .{s});
    return s[close + 2 ..];
}

/// The structure `report.json` documents: format, version, nodes, edges
/// between the nodes, and findings that name a rule and a reason.
pub fn json(gpa: std.mem.Allocator, text: []const u8) Error!void {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, text, .{}) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => fail(error.InvalidJson, "json: {t}", .{err}),
    };
    defer parsed.deinit();
    const root = try object(parsed.value, "the report");
    if (!std.mem.eql(u8, try string(root, "format"), "gantry")) return fail(error.InvalidJson, "json: format is not gantry", .{});
    const version = root.get("version") orelse return fail(error.InvalidJson, "json: no version", .{});
    if (version != .integer or version.integer != 1) return fail(error.InvalidJson, "json: version is not 1", .{});
    const nodes = try array(root, "nodes");
    for (nodes) |node| _ = try string(try object(node, "a node"), "path");
    for (try array(root, "edges")) |edge_value| try edge(edge_value, nodes);
    if (root.get("findings")) |_| for (try array(root, "findings")) |finding| {
        const fields = try object(finding, "a finding");
        _ = try string(fields, "rule");
        _ = try string(fields, "reason");
        if (fields.get("edge")) |e| try edge(e, nodes);
        if (fields.get("chain")) |chain| {
            if (chain != .array) return fail(error.InvalidJson, "json: a chain is not an array", .{});
            for (chain.array.items) |step| if (step != .string) return fail(error.InvalidJson, "json: a chain holds a non-path", .{});
        }
    };
}

fn edge(value: std.json.Value, nodes: []const std.json.Value) Error!void {
    const fields = try object(value, "an edge");
    for ([_][]const u8{ "from", "to" }) |end| {
        const path = try string(fields, end);
        var found = false;
        for (nodes) |node| found = found or std.mem.eql(u8, node.object.get("path").?.string, path);
        if (!found) return fail(error.InvalidJson, "json: an edge ends at '{s}', no node", .{path});
    }
    const kind = try string(fields, "kind");
    _ = std.meta.stringToEnum(g.Kind, kind) orelse return fail(error.InvalidJson, "json: '{s}' is no edge kind", .{kind});
    const count = fields.get("count") orelse return fail(error.InvalidJson, "json: an edge without a count", .{});
    if (count != .integer or count.integer < 1) return fail(error.InvalidJson, "json: an edge count is not a positive integer", .{});
}

fn object(value: std.json.Value, what: []const u8) Error!std.json.ObjectMap {
    if (value != .object) return fail(error.InvalidJson, "json: {s} is not an object", .{what});
    return value.object;
}

fn string(fields: std.json.ObjectMap, name: []const u8) Error![]const u8 {
    const value = fields.get(name) orelse return fail(error.InvalidJson, "json: no '{s}'", .{name});
    if (value != .string) return fail(error.InvalidJson, "json: '{s}' is not a string", .{name});
    return value.string;
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

test "dot accepts what gantry writes and refuses what is not a digraph" {
    try dot("digraph \"g\" {\n  rankdir=LR;\n  node [shape=box, style=rounded];\n  \"a\" [label=\"x\"];\n  subgraph \"c\" {\n    \"b\";\n  }\n  \"a\" -> \"b\" [color=\"#cc0000\"];\n}\n");
    try std.testing.expectError(error.InvalidDot, dot("graph g {}"));
    try std.testing.expectError(error.InvalidDot, dot("digraph \"g\" {\n  \"a\"\n}\n"));
    try std.testing.expectError(error.InvalidDot, dot("digraph \"g\" {\n  \"a\" -> ;\n}\n"));
    try std.testing.expectError(error.InvalidDot, dot("digraph \"g\" {\n  \"a [label=\"x\"];\n}\n"));
    try std.testing.expectError(error.InvalidDot, dot("digraph \"g\" {\n  \"a\" [label=\"x\";\n}\n"));
    try std.testing.expectError(error.InvalidDot, dot("digraph \"g\" {\n  \"a\";\n"));
    try std.testing.expectError(error.InvalidDot, dot("digraph \"g\" {\n  \"a\";\n}\n}\n"));
}

test "mermaid accepts what gantry writes and refuses a broken chart" {
    try mermaid("flowchart LR\n  classDef finding stroke:#cc0000\n  n0[\"a\"]\n  subgraph d0[\"d\"]\n    n1[\"b\"]:::finding\n  end\n  n0 -.->|link| n1\n  n1 --> n0\n  linkStyle 1 stroke:#cc0000\n");
    try std.testing.expectError(error.InvalidMermaid, mermaid("graph LR\n  n0[\"a\"]\n"));
    try std.testing.expectError(error.InvalidMermaid, mermaid("flowchart LR\n  n0[\"a\"]\n  n0 --> n1\n"));
    try std.testing.expectError(error.InvalidMermaid, mermaid("flowchart LR\n  subgraph d0[\"d\"]\n    n0[\"a\"]\n"));
    try std.testing.expectError(error.InvalidMermaid, mermaid("flowchart LR\n  n0[\"a\"q\"]\n"));
    try std.testing.expectError(error.InvalidMermaid, mermaid("flowchart LR\n  n0[\"a\"]\n  n0 --> n0\n  linkStyle 3 stroke:#cc0000\n"));
    try std.testing.expectError(error.InvalidMermaid, mermaid("flowchart LR\n  end\n"));
}

test "json holds the structure the report documents" {
    const a = std.testing.allocator;
    try json(a, "{\"format\":\"gantry\",\"version\":1,\"nodes\":[{\"path\":\"a\"},{\"path\":\"b\"}],\"edges\":[{\"from\":\"a\",\"to\":\"b\",\"kind\":\"import\",\"count\":1}],\"findings\":[{\"rule\":\"r\",\"reason\":\"forbidden\",\"chain\":[\"a\",\"b\"]}]}");
    try std.testing.expectError(error.InvalidJson, json(a, "{\"format\":\"gantry\",\"version\":2,\"nodes\":[],\"edges\":[]}"));
    try std.testing.expectError(error.InvalidJson, json(a, "{\"format\":\"gantry\",\"version\":1,\"nodes\":[{\"path\":\"a\"}],\"edges\":[{\"from\":\"a\",\"to\":\"z\",\"kind\":\"import\",\"count\":1}]}"));
    try std.testing.expectError(error.InvalidJson, json(a, "{\"format\":\"gantry\",\"version\":1,\"nodes\":[{\"path\":\"a\"}],\"edges\":[{\"from\":\"a\",\"to\":\"a\",\"kind\":\"sideways\",\"count\":1}]}"));
    try std.testing.expectError(error.InvalidJson, json(a, "{\"format\":\"gantry\",\"version\":1,\"nodes\":[{\"path\":\"a\"}],\"edges\":[],\"findings\":[{\"rule\":\"r\"}]}"));
    try std.testing.expectError(error.InvalidJson, json(a, "{\"format\":\"gantry\""));
}
