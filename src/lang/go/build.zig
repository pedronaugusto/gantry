//! Constraints are retained as data. Evaluation requires a caller target.
const std = @import("std");
const l = @import("../../lexer.zig");
const p = @import("../../path.zig");
pub const Target = struct { os: []const u8, arch: []const u8, tags: []const []const u8 = &.{} };
pub const File = struct {
    path: []const u8,
    package: []const u8 = "",
    constraint: ?[]const u8 = null,
    os: ?[]const u8 = null,
    arch: ?[]const u8 = null,
    selected: bool = true,
};
const systems = &[_][]const u8{ "aix", "android", "darwin", "dragonfly", "freebsd", "hurd", "illumos", "ios", "js", "linux", "nacl", "netbsd", "openbsd", "plan9", "solaris", "wasip1", "windows", "zos" };
const arches = &[_][]const u8{ "386", "amd64", "amd64p32", "arm", "armbe", "arm64", "arm64be", "loong64", "mips", "mipsle", "mips64", "mips64le", "mips64p32", "mips64p32le", "ppc", "ppc64", "ppc64le", "riscv", "riscv64", "s390", "s390x", "sparc", "sparc64", "wasm" };
fn contains(list: []const []const u8, value: []const u8) bool {
    for (list) |s| if (std.mem.eql(u8, s, value)) return true;
    return false;
}
fn tag(target: Target, name: []const u8) bool {
    if (std.mem.eql(u8, target.os, name) or std.mem.eql(u8, target.arch, name) or contains(target.tags, name)) return true;
    if (std.mem.eql(u8, target.os, "android") and std.mem.eql(u8, name, "linux")) return true;
    if (std.mem.eql(u8, target.os, "illumos") and std.mem.eql(u8, name, "solaris")) return true;
    if (std.mem.eql(u8, target.os, "ios") and std.mem.eql(u8, name, "darwin")) return true;
    return std.mem.eql(u8, name, "unix") and contains(&.{ "aix", "android", "darwin", "dragonfly", "freebsd", "hurd", "illumos", "ios", "linux", "netbsd", "openbsd", "solaris" }, target.os);
}
const Op = enum { open, either, both, negate };
fn apply(values: *std.ArrayList(bool), op: Op) !void {
    const rhs = values.pop() orelse return error.InvalidBuildConstraint;
    if (op == .negate) {
        try values.appendBounded(!rhs);
        return;
    }
    const lhs = values.pop() orelse return error.InvalidBuildConstraint;
    try values.appendBounded(switch (op) {
        .both => lhs and rhs,
        .either => lhs or rhs,
        else => return error.InvalidBuildConstraint,
    });
}
pub fn evaluate(a: std.mem.Allocator, expression: []const u8, target: Target) !bool {
    var values: std.ArrayList(bool) = .empty;
    defer values.deinit(a);
    var ops: std.ArrayList(Op) = .empty;
    defer ops.deinit(a);
    var operand = true;
    var i: usize = 0;
    while (i < expression.len) {
        const c = expression[i];
        if (std.ascii.isWhitespace(c)) {
            i += 1;
            continue;
        }
        if (operand) {
            if (c == '!') {
                try ops.append(a, .negate);
                i += 1;
                continue;
            }
            if (c == '(') {
                try ops.append(a, .open);
                i += 1;
                continue;
            }
            const start = i;
            while (i < expression.len and (std.ascii.isAlphanumeric(expression[i]) or expression[i] == '_' or expression[i] == '.')) : (i += 1) {}
            if (i == start) return error.InvalidBuildConstraint;
            try values.append(a, tag(target, expression[start..i]));
            operand = false;
        } else if (c == ')') {
            while (ops.getLastOrNull()) |op| {
                if (op == .open) break;
                _ = ops.pop();
                try apply(&values, op);
            }
            if (ops.pop() == null) return error.InvalidBuildConstraint;
            i += 1;
        } else {
            const op: Op = if (std.mem.startsWith(u8, expression[i..], "&&")) .both else if (std.mem.startsWith(u8, expression[i..], "||")) .either else return error.InvalidBuildConstraint;
            while (ops.getLastOrNull()) |previous| {
                if (previous == .open or @intFromEnum(previous) < @intFromEnum(op)) break;
                _ = ops.pop();
                try apply(&values, previous);
            }
            try ops.append(a, op);
            operand = true;
            i += 2;
        }
    }
    if (operand) return error.InvalidBuildConstraint;
    while (ops.pop()) |op| try apply(&values, op);
    if (values.items.len != 1) return error.InvalidBuildConstraint;
    return values.items[0];
}
pub fn parse(a: std.mem.Allocator, file: []const u8, text: []const u8, target: ?Target) !File {
    return parseTokens(a, file, text, target, try l.lexCompact(.go, a, text, null));
}
pub fn parseTokens(a: std.mem.Allocator, file: []const u8, text: []const u8, target: ?Target, ts: []const l.Token) !File {
    var result: File = .{ .path = file };
    for (ts, 0..) |token, i| if (token.is("package") and i + 1 < ts.len) {
        result.package = try a.dupe(u8, ts[i + 1].text);
        break;
    };
    // Only leading line comments can be directives; text inside block comments
    // and strings must never become build constraints.
    var lines = std.mem.splitScalar(u8, text, '\n');
    var in_block = false;
    while (lines.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \t\r");
        while (line.len > 0) {
            if (in_block) {
                const end = std.mem.indexOf(u8, line, "*/") orelse break;
                line = std.mem.trimStart(u8, line[end + 2 ..], " \t\r");
                in_block = false;
            } else if (std.mem.startsWith(u8, line, "/*")) {
                in_block = true;
                line = line[2..];
            } else break;
        }
        if (in_block or line.len == 0) continue;
        if (!std.mem.startsWith(u8, line, "//")) break;
        const prefix = "//go:build";
        if (std.mem.startsWith(u8, line, prefix) and (line.len == prefix.len or std.ascii.isWhitespace(line[prefix.len]))) {
            if (result.constraint != null) return error.InvalidBuildConstraint;
            result.constraint = try a.dupe(u8, std.mem.trim(u8, line[prefix.len..], " \t\r"));
        }
    }
    const base = p.base(file);
    var stem = base[0 .. base.len - 3];
    if (std.mem.endsWith(u8, stem, "_test")) stem = stem[0 .. stem.len - 5];
    if (std.mem.lastIndexOfScalar(u8, stem, '_')) |last| {
        const suffix = stem[last + 1 ..];
        if (contains(systems, suffix)) result.os = suffix;
        if (contains(arches, suffix)) {
            result.arch = suffix;
            if (std.mem.lastIndexOfScalar(u8, stem[0..last], '_')) |previous| {
                const os = stem[previous + 1 .. last];
                if (contains(systems, os)) result.os = os;
            }
        }
    }
    if (target) |selected| {
        if (result.os) |os| result.selected = result.selected and tag(selected, os);
        if (result.arch) |arch| result.selected = result.selected and std.mem.eql(u8, selected.arch, arch);
        if (result.constraint) |expression| result.selected = (try evaluate(a, expression, selected)) and result.selected;
        if (std.mem.startsWith(u8, base, "_") or std.mem.startsWith(u8, base, ".")) result.selected = false;
    }
    return result;
}
