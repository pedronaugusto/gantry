const std = @import("std");
const l = @import("../lexer.zig");
const types = @import("../types.zig");
const Spec = types.Spec;
/// The token stream recovery reads; `seen` observes it as it grows.
pub fn lex(a: std.mem.Allocator, source: []const u8, seen: ?l.Observer) ![]const l.Token {
    return l.lexCompact(.javascript, a, source, seen);
}
pub fn recover(a: std.mem.Allocator, source: []const u8) !types.Recovery {
    return recoverTokens(a, source, try lex(a, source, null));
}
pub fn recoverTokens(a: std.mem.Allocator, _: []const u8, ts: []const l.Token) !types.Recovery {
    var out: std.ArrayList(Spec) = .empty;
    var unsupported: std.ArrayList(types.UnsupportedReference) = .empty;
    for (ts, 0..) |t, i| {
        if (i > 0 and (ts[i - 1].is(".") or ts[i - 1].is("?"))) continue;
        if (t.is("require") or t.is("import")) {
            if (i + 3 < ts.len and ts[i + 1].is("(") and ts[i + 2].kind == .string and (ts[i + 3].is(")") or ts[i + 3].is(","))) {
                try out.append(a, .{ .name = try l.decodeJS(a, ts[i + 2].text), .offset = t.offset });
                continue;
            }
            if (i + 1 < ts.len and ts[i + 1].is("(")) {
                try unsupported.append(a, .{ .offset = t.offset, .expression = if (t.is("require")) .javascript_require else .javascript_import });
                continue;
            }
            if (t.is("require")) continue;
            if (i + 1 < ts.len and ts[i + 1].kind == .string) {
                try out.append(a, .{ .name = try l.decodeJS(a, ts[i + 1].text), .offset = t.offset });
                continue;
            }
        } else if (!t.is("export")) continue;
        var j = i + 1;
        while (j < ts.len and !ts[j].is(";") and !ts[j].is("=")) : (j += 1) {
            if (ts[j].is("from") and j + 1 < ts.len and ts[j + 1].kind == .string) {
                try out.append(a, .{ .name = try l.decodeJS(a, ts[j + 1].text), .offset = t.offset });
                break;
            }
            if (ts[j].is("import") or ts[j].is("export")) break;
        }
    }
    return .{ .specs = try out.toOwnedSlice(a), .unsupported = try unsupported.toOwnedSlice(a) };
}

const p = @import("../path.zig");
// TypeScript extension substitution precedes runtime extensions.
fn file(c: anytype, root: []const u8, name: []const u8) !?[]const u8 {
    const ext = std.fs.path.extension(name);
    if (std.mem.eql(u8, ext, ".js") or std.mem.eql(u8, ext, ".jsx")) {
        return c.candidate(root, name[0 .. name.len - ext.len], &.{ ".ts", ".tsx", ".d.ts", ".js", ".jsx" });
    }
    if (std.mem.eql(u8, ext, ".mjs")) return c.candidate(root, name[0 .. name.len - 4], &.{ ".mts", ".d.mts", ".mjs" });
    if (std.mem.eql(u8, ext, ".cjs")) return c.candidate(root, name[0 .. name.len - 4], &.{ ".cts", ".d.cts", ".cjs" });
    return c.candidate(root, name, &.{ "", ".ts", ".tsx", ".d.ts", ".js", ".jsx", ".mts", ".d.mts", ".mjs", ".cts", ".d.cts", ".cjs", "/index.ts", "/index.tsx", "/index.d.ts", "/index.js", "/index.jsx" });
}
pub fn resolve(c: anytype, from: []const u8, spec: Spec) ![]const []const u8 {
    const name = spec.name;
    var target: ?[]const u8 = null;
    if (std.mem.startsWith(u8, name, "./") or std.mem.startsWith(u8, name, "../")) {
        target = try file(c, p.dir(from), name);
    } else if (@import("../tsconfig.zig").nearest(c.ts_configs, from)) |cfg| {
        var best: ?@import("../tsconfig.zig").Mapping = null;
        var capture: []const u8 = "";
        var length: usize = 0;
        if (cfg.mappings) |mappings| for (mappings) |m| {
            if (std.mem.indexOfScalar(u8, m.pattern, '*')) |star| {
                const tail = m.pattern[star + 1 ..];
                if (name.len < star + tail.len or !std.mem.startsWith(u8, name, m.pattern[0..star]) or !std.mem.endsWith(u8, name, tail)) continue;
                if (best == null or star > length) {
                    best = m;
                    capture = name[star .. name.len - tail.len];
                    length = star;
                }
            } else if (std.mem.eql(u8, m.pattern, name)) {
                best = m;
                capture = "";
                length = std.math.maxInt(usize);
            }
        };
        if (best) |m| for (m.targets) |replacement| {
            const substituted = try std.mem.replaceOwned(u8, c.allocator, replacement, "*", capture);
            target = try file(c, cfg.base_url orelse cfg.paths_root, substituted);
            if (target != null) break;
        };
        if (target == null) if (cfg.base_url) |base| {
            target = try file(c, base, name);
        };
    }
    return if (target) |v| try c.allocator.dupe([]const u8, &.{v}) else &.{};
}
pub const extensions = &[_][]const u8{ ".js", ".mjs", ".cjs", ".jsx", ".ts", ".tsx", ".mts", ".cts" };
