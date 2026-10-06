//! JSON for a graph and its findings, SARIF 2.1.0 for findings, and the
//! byte escapes every report shares.
const graph_module = @import("../graph.zig");
const check_module = @import("../rules/check.zig");
const std = @import("std");
const t = @import("../types.zig");
const Graph = graph_module.Graph;
const Violation = check_module.Violation;
const Writer = std.Io.Writer;
const diagnostic_module = @import("../scan/diagnostic.zig");
/// What writing a report fails with: the writer's error (`Writer.Error`),
/// or memory.
pub const Error = error{ WriteFailed, OutOfMemory };

/// The length of the UTF-8 sequence that starts at `s[i]`, or null for a
/// byte that starts no valid one (overlong forms and surrogates included).
pub fn sequence(s: []const u8, i: usize) ?usize {
    const n = std.unicode.utf8ByteSequenceLength(s[i]) catch return null;
    if (i + n > s.len) return null;
    if (!std.unicode.utf8ValidateSlice(s[i..][0..n])) return null;
    return n;
}

/// A JSON string. A byte that is not UTF-8 is written as U+FFFD.
pub fn string(w: *Writer, s: []const u8) Writer.Error!void {
    try w.writeByte('"');
    try body(w, s);
    try w.writeByte('"');
}

fn body(w: *Writer, s: []const u8) Writer.Error!void {
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0...0x08, 0x0b, 0x0c, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{c}),
            0x20...0x21, 0x23...0x5b, 0x5d...0x7f => try w.writeByte(c),
            else => if (sequence(s, i)) |n| {
                try w.writeAll(s[i..][0..n]);
                i += n;
                continue;
            } else try w.writeAll("\\ufffd"),
        }
        i += 1;
    }
}

/// The graph's nodes and edges with the findings, in one JSON object:
///
///     {"format": "gantry", "version": 1,
///      "nodes": [{"path"}],
///      "edges": [{"from", "to", "kind", "count"}],
///      "findings": [{"rule", "reason", "edge"?, "reference"?, "token"?,
///                    "path"?, "dependency"?, "package"?, "chain"?}]}
///
/// Nodes and edges are in the graph's order (by path, then target and
/// kind), findings in the order given. A finding carries only the fields
/// its rule set: `edge` as an edge, `reference` as {"from", "name",
/// "offset", "member"?, "resolved", "kind"}, `token` as {"path", "kind",
/// "text", "offset", "line", "column"} (a byte column), `dependency` as
/// {"manifest", "name", "requirement", "source", "group", "origin",
/// "scope"}, and `chain` as paths. Offsets are bytes. `version` changes
/// only when a field changes meaning or goes away.
pub fn json(w: *Writer, graph: *const Graph, findings: []const Violation) Writer.Error!void {
    try w.writeAll("{\n  \"format\": \"gantry\",\n  \"version\": 1,\n  \"nodes\": [");
    for (graph.paths(), 0..) |p, i| {
        try w.writeAll(if (i == 0) "\n    {\"path\": " else ",\n    {\"path\": ");
        try string(w, p);
        try w.writeByte('}');
    }
    try w.writeAll(if (graph.paths().len == 0) "],\n  \"edges\": [" else "\n  ],\n  \"edges\": [");
    for (graph.edges(), 0..) |e, i| {
        try w.writeAll(if (i == 0) "\n    " else ",\n    ");
        try edge(w, e);
    }
    try w.writeAll(if (graph.edges().len == 0) "],\n  \"findings\": [" else "\n  ],\n  \"findings\": [");
    for (findings, 0..) |f, i| {
        try w.writeAll(if (i == 0) "\n    {\"rule\": " else ",\n    {\"rule\": ");
        try string(w, f.rule);
        try w.print(", \"reason\": \"{s}\"", .{@tagName(f.reason)});
        if (f.edge) |e| {
            try w.writeAll(", \"edge\": ");
            try edge(w, e.*);
        }
        if (f.reference) |r| {
            try w.writeAll(", \"reference\": {\"from\": ");
            try string(w, r.from);
            try w.writeAll(", \"name\": ");
            try string(w, r.name);
            try w.print(", \"offset\": {d}", .{r.offset});
            if (r.member) |m| {
                try w.writeAll(", \"member\": ");
                try string(w, m);
            }
            try w.print(", \"resolved\": {}, \"kind\": \"{s}\"}}", .{ r.resolved, @tagName(r.kind) });
        }
        if (f.token) |k| {
            try w.writeAll(", \"token\": {\"path\": ");
            try string(w, k.path);
            try w.print(", \"kind\": \"{s}\", \"text\": ", .{@tagName(k.kind)});
            try string(w, k.text);
            try w.print(", \"offset\": {d}, \"line\": {d}, \"column\": {d}}}", .{ k.offset, k.line, k.column });
        }
        if (f.path) |p| {
            try w.writeAll(", \"path\": ");
            try string(w, p);
        }
        if (f.dependency) |d| {
            try w.writeAll(", \"dependency\": {\"manifest\": ");
            try string(w, d.manifest);
            inline for (.{ "name", "requirement", "source", "group" }) |field| {
                try w.writeAll(", \"" ++ field ++ "\": ");
                try string(w, @field(d, field));
            }
            try w.print(", \"origin\": \"{s}\", \"scope\": \"{s}\"}}", .{ @tagName(d.origin), @tagName(d.scope()) });
        }
        if (f.package) |p| {
            try w.writeAll(", \"package\": ");
            try string(w, p);
        }
        if (f.chain.len > 0) {
            try w.writeAll(", \"chain\": [");
            for (f.chain, 0..) |p, j| {
                if (j > 0) try w.writeAll(", ");
                try string(w, p);
            }
            try w.writeByte(']');
        }
        try w.writeByte('}');
    }
    try w.writeAll(if (findings.len == 0) "]\n}\n" else "\n  ]\n}\n");
}

fn edge(w: *Writer, e: t.Edge) Writer.Error!void {
    try w.writeAll("{\"from\": ");
    try string(w, e.from);
    try w.writeAll(", \"to\": ");
    try string(w, e.to);
    try w.print(", \"kind\": \"{s}\", \"count\": {d}}}", .{ @tagName(e.kind), e.count });
}

pub const SarifOptions = struct {
    /// Written before every path in a location: where the scanned root
    /// sits in the repository, ending in `/`, or empty for its top.
    uri_prefix: []const u8 = "",
};

/// Findings as a SARIF 2.1.0 log of one run, for GitHub code scanning and
/// other SARIF readers. Each rule name is a rule id, listed once in name
/// order; each finding is an `error` result at the file it is about, in
/// the order given. Only a token finding has a line here; `sarifWithSource`
/// gives reference and undeclared findings theirs, and columns. Edge,
/// path and declaration findings are about a whole file.
pub fn sarif(gpa: std.mem.Allocator, w: *Writer, findings: []const Violation, options: SarifOptions) Error!void {
    const positions = try gpa.alloc(?Position, findings.len);
    defer gpa.free(positions);
    for (findings, positions) |f, *p| p.* = if (f.token) |k| .{ .line = k.line } else null;
    try writeSarif(gpa, w, findings, positions, options);
}

/// `sarif`, reading each file a reference or token finding names once,
/// with `read(scratch_allocator, context, path) !?[]const u8` as `scan`
/// takes it, to place those findings at a line and column (in Unicode
/// code points). A null read, or an offset past the bytes, leaves the
/// finding where `sarif` puts it; a read error is returned.
pub fn sarifWithSource(gpa: std.mem.Allocator, w: *Writer, findings: []const Violation, context: anytype, comptime read: anytype, options: SarifOptions) (Error || diagnostic_module.ReadError(read))!void {
    const positions = try gpa.alloc(?Position, findings.len);
    defer gpa.free(positions);
    for (findings, positions) |f, *p| p.* = if (f.token) |k| .{ .line = k.line } else null;
    const Spot = struct {
        const Self = @This();
        path: []const u8,
        offset: usize,
        finding: usize,
        fn less(_: void, a: Self, b: Self) bool {
            const order = std.mem.order(u8, a.path, b.path);
            return if (order != .eq) order == .lt else a.offset < b.offset;
        }
    };
    var spots: std.ArrayList(Spot) = .empty;
    defer spots.deinit(gpa);
    for (findings, 0..) |f, i| {
        if (f.reference) |r| try spots.append(gpa, .{ .path = r.from, .offset = r.offset, .finding = i }) else if (f.token) |k| try spots.append(gpa, .{ .path = k.path, .offset = k.offset, .finding = i });
    }
    std.mem.sort(Spot, spots.items, {}, Spot.less);
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    var s: usize = 0;
    while (s < spots.items.len) {
        const file = spots.items[s].path;
        var end = s + 1;
        while (end < spots.items.len and std.mem.eql(u8, spots.items[end].path, file)) end += 1;
        defer s = end;
        _ = scratch.reset(.retain_capacity);
        const bytes = (try read(scratch.allocator(), context, file)) orelse continue;
        var line: usize = 1;
        var start: usize = 0;
        var at: usize = 0;
        for (spots.items[s..end]) |spot| {
            if (spot.offset > bytes.len) continue;
            while (at < spot.offset) : (at += 1) if (bytes[at] == '\n') {
                line += 1;
                start = at + 1;
            };
            var column: usize = 1;
            for (bytes[start..spot.offset]) |b| column += @intFromBool(b & 0xc0 != 0x80);
            positions[spot.finding] = .{ .line = line, .column = column };
        }
    }
    try writeSarif(gpa, w, findings, positions, options);
}

const Position = struct { line: usize, column: ?usize = null };

fn writeSarif(gpa: std.mem.Allocator, w: *Writer, findings: []const Violation, positions: []const ?Position, options: SarifOptions) !void {
    const names = try gpa.alloc([]const u8, findings.len);
    defer gpa.free(names);
    for (findings, names) |f, *n| n.* = f.rule;
    std.mem.sort([]const u8, names, {}, t.stringsLess);
    var count: usize = 0;
    for (names) |n| if (count == 0 or !std.mem.eql(u8, names[count - 1], n)) {
        names[count] = n;
        count += 1;
    };
    const ids = names[0..count];

    try w.writeAll(
        \\{
        \\  "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
        \\  "version": "2.1.0",
        \\  "runs": [
        \\    {
        \\      "tool": {
        \\        "driver": {
        \\          "name": "gantry",
        \\          "informationUri": "https://github.com/pedronaugusto/gantry",
        \\          "rules": [
    );
    for (ids, 0..) |id, i| {
        try w.writeAll(if (i == 0) "\n            {\"id\": " else ",\n            {\"id\": ");
        try string(w, id);
        try w.writeAll(", \"defaultConfiguration\": {\"level\": \"error\"}}");
    }
    try w.writeAll(if (ids.len == 0) "]\n" else "\n          ]\n");
    try w.writeAll(
        \\        }
        \\      },
        \\      "columnKind": "unicodeCodePoints",
        \\      "results": [
    );
    for (findings, positions, 0..) |f, position, i| {
        const index = std.sort.lowerBound([]const u8, ids, f.rule, struct {
            fn order(key: []const u8, item: []const u8) std.math.Order {
                return std.mem.order(u8, key, item);
            }
        }.order);
        try w.writeAll(if (i == 0) "\n        {\"ruleId\": " else ",\n        {\"ruleId\": ");
        try string(w, f.rule);
        try w.print(", \"ruleIndex\": {d}, \"level\": \"error\", \"message\": {{\"text\": \"", .{index});
        try message(w, f);
        try w.writeAll("\"}, \"locations\": [{\"physicalLocation\": {\"artifactLocation\": {\"uri\": \"");
        try uri(w, options.uri_prefix);
        try uri(w, subject(f));
        try w.writeAll("\"}");
        if (position) |p| {
            try w.print(", \"region\": {{\"startLine\": {d}", .{p.line});
            if (p.column) |c| try w.print(", \"startColumn\": {d}", .{c});
            try w.writeByte('}');
        }
        try w.writeAll("}}]}");
    }
    try w.writeAll(if (findings.len == 0) "]\n" else "\n      ]\n");
    try w.writeAll(
        \\    }
        \\  ]
        \\}
        \\
    );
}

/// The file a finding is about.
fn subject(f: Violation) []const u8 {
    if (f.reference) |r| return r.from;
    if (f.token) |k| return k.path;
    if (f.dependency) |d| return d.manifest;
    if (f.edge) |e| return e.from;
    return f.path orelse "";
}

fn message(w: *Writer, f: Violation) Writer.Error!void {
    switch (f.reason) {
        .upward, .forbidden => if (f.chain.len > 0) {
            for (f.chain, 0..) |p, i| {
                if (i > 0) try w.writeAll(" -> ");
                try body(w, p);
            }
            try w.writeAll(if (f.reason == .upward) " reaches a higher layer" else " is a forbidden chain");
        } else {
            try body(w, f.edge.?.from);
            try w.writeAll(" -> ");
            try body(w, f.edge.?.to);
            try w.writeAll(if (f.reason == .upward) " goes up a layer" else " is forbidden");
        },
        .entry => {
            try body(w, f.edge.?.from);
            try w.writeAll(" imports ");
            try body(w, f.edge.?.to);
            try w.writeAll(", which nothing may import");
        },
        .cycle => {
            try body(w, f.edge.?.from);
            try w.writeAll(" -> ");
            try body(w, f.edge.?.to);
            try w.writeAll(" is in a cycle");
        },
        .reference => {
            try body(w, f.reference.?.from);
            try w.writeAll(" names ");
            try body(w, f.reference.?.name);
            if (f.reference.?.member) |m| {
                try w.writeByte('.');
                try body(w, m);
            }
        },
        .token => {
            try body(w, f.token.?.text);
            try w.writeAll(" is spelled outside its owners");
        },
        .missing => {
            try body(w, f.path.?);
            try w.writeAll(" is required and missing");
        },
        .unreached => {
            try body(w, f.path.?);
            try w.writeAll(" is reached from no entry");
        },
        .undeclared => {
            try body(w, f.package.?);
            try w.writeAll(" is imported and not declared in ");
            try body(w, f.path.?);
        },
        .unused => {
            try body(w, f.dependency.?.name);
            try w.writeAll(" is declared in ");
            try body(w, f.dependency.?.manifest);
            try w.writeAll(" and imported by no file it governs");
        },
    }
}

/// A relative URI reference: every byte outside RFC 3986's unreserved set
/// and `/` is percent-encoded, so a path's bytes all survive.
fn uri(w: *Writer, p: []const u8) Writer.Error!void {
    for (p) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~', '/' => try w.writeByte(c),
        else => try w.print("%{X:0>2}", .{c}),
    };
}
