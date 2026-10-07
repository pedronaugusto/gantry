//! `.nimble` requirements: NimScript read lexically, never run.
const std = @import("std");
const l = @import("../lexer.zig");
const t = @import("../types.zig");

/// `requires` (runtime), `taskRequires "task", …` (development) and
/// `requires` inside a `feature "name":` block (optional), each argument a
/// string literal. `when` conditions are not evaluated, so every branch
/// counts. A statement with any other argument is unsupported and declares
/// nothing. The `nim` requirement names the compiler and is not a package.
pub fn parse(a: std.mem.Allocator, path: []const u8, text: []const u8, out: *std.ArrayList(t.Dependency), unsupported: *std.ArrayList(t.UnsupportedReference)) error{ InvalidManifest, InvalidEscape, OutOfMemory }!void {
    const ts = try l.lex(.nim, a, text);
    const Feature = struct { column: usize, name: []const u8 };
    var features: std.ArrayList(Feature) = .empty;
    var i: usize = 0;
    while (i < ts.len) : (i += 1) {
        const token = ts[i];
        if (token.kind == .newline) continue;
        const first = i == 0 or ts[i - 1].kind == .newline;
        if (first) {
            const line = if (std.mem.findScalarLast(u8, text[0..token.offset], '\n')) |n| n + 1 else 0;
            const column = token.offset - line;
            while (features.items.len > 0 and features.items[features.items.len - 1].column >= column) _ = features.pop();
            if (token.is("feature") and i + 1 < ts.len and ts[i + 1].kind == .string) {
                try features.append(a, .{ .column = column, .name = ts[i + 1].text });
                continue;
            }
        }
        if (!first and !ts[i - 1].is(";") and !ts[i - 1].is(":")) continue;
        const task = token.is("taskRequires");
        if (!task and !token.is("requires")) continue;
        var j = i + 1;
        const parens = j < ts.len and ts[j].is("(");
        if (parens) j += 1;
        var group: []const u8 = "requires";
        if (features.items.len > 0) group = try a.print("feature.{s}", .{features.items[features.items.len - 1].name});
        if (task) {
            if (j + 1 >= ts.len or ts[j].kind != .string or !ts[j + 1].is(",")) {
                try unsupported.append(a, .{ .offset = token.offset, .expression = .nimble_requires });
                continue;
            }
            group = try a.print("taskRequires.{s}", .{ts[j].text});
            j += 2;
        }
        const before = out.items.len;
        const literal = while (j < ts.len) {
            if (ts[j].kind != .string) break false;
            const value = l.decode(a, ts[j].text) catch |err| switch (err) {
                error.InvalidEscape => break false,
                else => |e| return e,
            };
            try requirement(a, path, group, value, out);
            j += 1;
            if (j < ts.len and ts[j].is(",")) {
                j += 1;
                while (j < ts.len and ts[j].kind == .newline) : (j += 1) {}
                continue;
            }
            if (parens) {
                if (j < ts.len and ts[j].is(")")) j += 1 else break false;
            }
            break j == ts.len or ts[j].kind == .newline or ts[j].is(";");
        } else false;
        if (!literal) {
            out.shrinkRetainingCapacity(before);
            try unsupported.append(a, .{ .offset = token.offset, .expression = .nimble_requires });
        }
        i = j -| 1;
    }
}
/// `name`, `name >= 1.0`, `name#head`, or a URL with an optional `#revision`.
fn requirement(a: std.mem.Allocator, path: []const u8, group: []const u8, raw: []const u8, out: *std.ArrayList(t.Dependency)) !void {
    const value = std.mem.trim(u8, raw, " \t");
    const url = std.mem.find(u8, value, "://") != null or std.mem.startsWith(u8, value, "git@");
    const end = if (url) std.mem.findAny(u8, value, " \t") orelse value.len else std.mem.findAny(u8, value, " \t<>=~^#@") orelse value.len;
    if (end == 0) return error.InvalidManifest;
    const spelled = value[0..end];
    const name = if (url) spelled[0 .. std.mem.findScalar(u8, spelled, '#') orelse spelled.len] else spelled;
    if (!url and std.ascii.eqlIgnoreCase(name, "nim")) return;
    try out.append(a, .{
        .manifest = path,
        .name = name,
        .requirement = std.mem.trim(u8, value[end..], " \t"),
        .source = if (url) spelled else "",
        .group = group,
        .origin = if (url) .remote else .registry,
    });
}
