const tsconfig_module = @import("../tsconfig.zig");
const std = @import("std");
const l = @import("../lexer.zig");
const types = @import("../types.zig");
const Spec = types.Spec;
/// The token stream recovery reads; `seen` observes it as it grows.
pub fn lex(arena: std.mem.Allocator, source: []const u8, seen: ?l.Observer) std.mem.Allocator.Error![]const l.Token {
    return l.lexCompact(.javascript, arena, source, seen);
}
pub fn recover(arena: std.mem.Allocator, source: []const u8) error{ InvalidEscape, OutOfMemory }!types.Recovery {
    return recoverTokens(arena, source, try lex(arena, source, null));
}
pub fn recoverTokens(arena: std.mem.Allocator, _: []const u8, ts: []const l.Token) error{ InvalidEscape, OutOfMemory }!types.Recovery {
    var out: std.ArrayList(Spec) = .empty;
    var unsupported: std.ArrayList(types.UnsupportedReference) = .empty;
    for (ts, 0..) |t, i| {
        if (i > 0 and (ts[i - 1].is(".") or ts[i - 1].is("?"))) continue;
        if (t.is("require") or t.is("import")) {
            if (i + 3 < ts.len and ts[i + 1].is("(") and ts[i + 2].kind == .string and (ts[i + 3].is(")") or ts[i + 3].is(","))) {
                const kind: types.Kind = if (t.is("require")) (if (typeOnlyRequire(ts, i)) .type_only else .import) else callKind(ts, i);
                try out.append(arena, .{ .name = try l.decodeJs(arena, ts[i + 2].text), .offset = t.offset, .kind = kind });
                continue;
            }
            if (i + 1 < ts.len and ts[i + 1].is("(")) {
                try unsupported.append(arena, .{ .offset = t.offset, .expression = if (t.is("require")) .javascript_require else .javascript_import });
                continue;
            }
            if (t.is("require")) continue;
            if (i + 1 < ts.len and ts[i + 1].kind == .string) {
                try out.append(arena, .{ .name = try l.decodeJs(arena, ts[i + 1].text), .offset = t.offset });
                continue;
            }
        } else if (!t.is("export")) continue;
        var j = i + 1;
        while (j < ts.len and !ts[j].is(";") and !ts[j].is("=")) : (j += 1) {
            if (ts[j].is("from") and j + 1 < ts.len and ts[j + 1].kind == .string) {
                try out.append(arena, .{ .name = try l.decodeJs(arena, ts[j + 1].text), .offset = t.offset, .kind = if (typeOnlyClause(ts[i + 1 .. j])) .type_only else .import });
                break;
            }
            if (ts[j].is("import") or ts[j].is("export")) break;
        }
    }
    return .{ .specs = try out.toOwnedSlice(arena), .unsupported = try unsupported.toOwnedSlice(arena) };
}
/// `import("x")` loads a module when it runs, unless it stands in a type:
/// after `typeof`, or before a member that is not a promise's own.
fn callKind(ts: []const l.Token, i: usize) types.Kind {
    if (i > 0 and ts[i - 1].is("typeof")) return .type_only;
    if (i + 5 < ts.len and ts[i + 3].is(")") and ts[i + 4].is(".") and ts[i + 5].kind == .word) {
        for ([_][]const u8{ "then", "catch", "finally" }) |member| if (ts[i + 5].is(member)) return .dynamic;
        return .type_only;
    }
    return .dynamic;
}
/// `import type name = require("x")`.
fn typeOnlyRequire(ts: []const l.Token, i: usize) bool {
    return i >= 4 and ts[i - 1].is("=") and ts[i - 2].kind == .word and ts[i - 3].is("type") and ts[i - 4].is("import");
}
/// The tokens between `import` or `export` and `from` bring in types alone:
/// `type` before the bindings (`type from` and `type,` name a binding
/// called `type`), or braces alone whose every name is marked `type`.
fn typeOnlyClause(clause: []const l.Token) bool {
    if (clause.len == 0) return false;
    if (clause[0].is("type")) return clause.len > 1 and !clause[1].is(",");
    if (!clause[0].is("{") or !clause[clause.len - 1].is("}")) return false;
    var names: usize = 0;
    var start: usize = 1;
    for (clause[1..], 1..) |token, k| {
        if (!token.is(",") and !token.is("}")) continue;
        const element = clause[start..k];
        start = k + 1;
        if (element.len == 0) continue;
        if (element.len < 2 or !element[0].is("type") or element[1].is("as")) return false;
        names += 1;
    }
    return names > 0;
}

const p = @import("../path.zig");
// TypeScript extension substitution precedes runtime extensions.
fn file(c: anytype, root: []const u8, name: []const u8) !?[]const u8 {
    const ext = std.Io.Dir.path.extension(name);
    if (std.mem.eql(u8, ext, ".js") or std.mem.eql(u8, ext, ".jsx")) {
        return c.candidate(root, name[0 .. name.len - ext.len], &.{ ".ts", ".tsx", ".d.ts", ".js", ".jsx" });
    }
    if (std.mem.eql(u8, ext, ".mjs")) return c.candidate(root, name[0 .. name.len - 4], &.{ ".mts", ".d.mts", ".mjs" });
    if (std.mem.eql(u8, ext, ".cjs")) return c.candidate(root, name[0 .. name.len - 4], &.{ ".cts", ".d.cts", ".cjs" });
    return c.candidate(root, name, &.{ "", ".ts", ".tsx", ".d.ts", ".js", ".jsx", ".mts", ".d.mts", ".mjs", ".cts", ".d.cts", ".cjs", "/index.ts", "/index.tsx", "/index.d.ts", "/index.js", "/index.jsx" });
}
pub fn resolve(c: anytype, from: []const u8, spec: Spec) types.ResolveError![]const []const u8 {
    const name = spec.name;
    var target: ?[]const u8 = null;
    if (std.mem.startsWith(u8, name, "./") or std.mem.startsWith(u8, name, "../")) {
        target = try file(c, p.dir(from), name);
    } else if (tsconfig_module.nearest(c.ts_configs, from)) |cfg| {
        var best: ?tsconfig_module.Mapping = null;
        var capture: []const u8 = "";
        var length: usize = 0;
        if (cfg.mappings) |mappings| for (mappings) |m| {
            if (std.mem.findScalar(u8, m.pattern, '*')) |star| {
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
