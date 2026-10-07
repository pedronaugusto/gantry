const std = @import("std");
const l = @import("../lexer.zig");
const types = @import("../types.zig");
const Spec = types.Spec;
/// The token stream recovery reads; `seen` observes it as it grows.
pub fn lex(arena: std.mem.Allocator, source: []const u8, seen: ?l.Observer) std.mem.Allocator.Error![]const l.Token {
    return l.lexSeen(.nim, arena, source, seen);
}
pub fn recover(arena: std.mem.Allocator, source: []const u8) std.mem.Allocator.Error!types.Recovery {
    return recoverTokens(arena, source, try lex(arena, source, null));
}
/// `import`, `include` and `from … import` statements name modules by path:
/// `a/b`, `std / os`, `../a`, `"a/b"`, `"."/a` and groups `a/[b, c]`. Symbols after
/// `from … import` and `except` are not modules. An operand that is not a
/// path, a group or a plain string is unsupported.
pub fn recoverTokens(arena: std.mem.Allocator, _: []const u8, ts: []const l.Token) std.mem.Allocator.Error!types.Recovery {
    var out: std.ArrayList(Spec) = .empty;
    var unsupported: std.ArrayList(types.UnsupportedReference) = .empty;
    var i: usize = 0;
    while (i < ts.len) : (i += 1) {
        const t = ts[i];
        const from = t.is("from");
        if (!from and !t.is("import") and !t.is("include")) continue;
        // A statement starts a line or follows `;` or a `when`/`else` colon.
        if (i > 0 and ts[i - 1].kind != .newline and !ts[i - 1].is(";") and !ts[i - 1].is(":")) continue;
        const expression: types.ImportExpression = if (t.is("include")) .nim_include else .nim_import;
        var j = i + 1;
        const before = out.items.len;
        const literal = while (true) {
            if (!try module(arena, ts, &j, t.offset, &out)) break false;
            // A pragma such as `{.all.}` and an alias belong to the module.
            if (j < ts.len and ts[j].is("{")) {
                while (j < ts.len and !ts[j].is("}") and ts[j].kind != .newline) : (j += 1) {}
                if (j < ts.len and ts[j].is("}")) j += 1;
            }
            alias(ts, &j);
            if (from) break j < ts.len and ts[j].is("import");
            if (j < ts.len and ts[j].is("except")) break true;
            if (j < ts.len and ts[j].is(",")) {
                j += 1;
                while (j < ts.len and ts[j].kind == .newline) : (j += 1) {}
                continue;
            }
            break j == ts.len or ts[j].kind == .newline or ts[j].is(";");
        };
        if (!literal) {
            // An unreadable statement contributes no guessed module.
            out.shrinkRetainingCapacity(before);
            try unsupported.append(arena, .{ .offset = t.offset, .expression = expression });
        }
        i = j -| 1;
    }
    return .{ .specs = try out.toOwnedSlice(arena), .unsupported = try unsupported.toOwnedSlice(arena) };
}
/// One module operand, which a bracket group expands into several.
fn module(arena: std.mem.Allocator, ts: []const l.Token, j: *usize, offset: usize, out: *std.ArrayList(Spec)) !bool {
    // The operand list can start on the next, indented line.
    while (j.* < ts.len and ts[j.*].kind == .newline) : (j.* += 1) {}
    const prefix = (try path(arena, ts, j)) orelse return false;
    if (prefix.len == 0) return false;
    if (!std.mem.endsWith(u8, prefix, "/") or j.* >= ts.len or !ts[j.*].is("[")) {
        if (std.mem.endsWith(u8, prefix, "/")) return false;
        try out.append(arena, .{ .name = prefix, .offset = offset });
        return true;
    }
    j.* += 1;
    while (true) {
        while (j.* < ts.len and ts[j.*].kind == .newline) : (j.* += 1) {}
        // A group can end with a trailing comma.
        if (j.* < ts.len and ts[j.*].is("]") and out.items.len > 0) {
            j.* += 1;
            return true;
        }
        const member = (try path(arena, ts, j)) orelse return false;
        if (member.len == 0 or std.mem.endsWith(u8, member, "/")) return false;
        try out.append(arena, .{ .name = try std.mem.concat(arena, u8, &.{ prefix, member }), .offset = offset });
        alias(ts, j);
        while (j.* < ts.len and ts[j.*].kind == .newline) : (j.* += 1) {}
        if (j.* < ts.len and ts[j.*].is(",")) {
            j.* += 1;
            continue;
        }
        if (j.* < ts.len and ts[j.*].is("]")) {
            j.* += 1;
            return true;
        }
        return false;
    }
}
fn alias(ts: []const l.Token, j: *usize) void {
    if (j.* + 1 < ts.len and ts[j.*].is("as") and ts[j.* + 1].kind == .word) j.* += 2;
}
/// Names and strings joined by `/`, with leading `.` and `..` components:
/// `a/b`, `std / os`, `../a`, `"a/b"`, `"."/x`, and `a.b` for `a/b`. Null
/// for an undecodable string.
fn path(arena: std.mem.Allocator, ts: []const l.Token, j: *usize) !?[]const u8 {
    var name: std.ArrayList(u8) = .empty;
    var last: enum { none, word, dot, slash } = .none;
    while (j.* < ts.len) : (j.* += 1) {
        const t = ts[j.*];
        if (t.is("/")) {
            if (last != .word and last != .dot) break;
            last = .slash;
        } else if (t.is(".")) {
            // `a.b` is the deprecated spelling of `a/b`.
            if (last == .word) {
                if (j.* + 1 >= ts.len or ts[j.* + 1].kind != .word) break;
                last = .slash;
                try name.append(arena, '/');
                continue;
            }
            last = .dot;
        } else if (t.kind == .string and (last == .none or last == .slash)) {
            last = .word;
            try name.appendSlice(arena, l.decode(arena, t.text) catch |err| switch (err) {
                error.InvalidEscape => return null,
                else => |e| return e,
            });
            continue;
        } else if (t.kind == .word and (last == .none or last == .slash) and !t.is("as") and !t.is("except") and !t.is("import")) {
            last = .word;
        } else break;
        try name.appendSlice(arena, t.text);
    }
    const value = try name.toOwnedSlice(arena);
    return value;
}

const p = @import("../path.zig");
/// Nim's own order (`findModule`): `std/` names only the standard library,
/// `pkg/` only search paths; any other name is first beside the importing
/// file, then, unless it starts with a dot, on the search paths. A name
/// without an extension is a `.nim` file.
pub fn resolve(c: anytype, from: []const u8, spec: Spec) types.ResolveError![]const []const u8 {
    const a = c.allocator;
    var name = spec.name;
    if (std.mem.startsWith(u8, name, "std/")) return &.{};
    const suffix: []const u8 = if (std.Io.Dir.path.extension(p.base(name)).len == 0) ".nim" else "";
    const package = std.mem.startsWith(u8, name, "pkg/");
    if (package) name = name[4..];
    if (!package) {
        if (try c.candidate(p.dir(from), name, &.{suffix})) |v| return a.dupe([]const u8, &.{v});
        if (name[0] == '.') return &.{};
    }
    // Nim inserts every `--path` first, so nearer configs and later lines win.
    var configs = std.mem.reverseIterator(c.nim_configs);
    while (configs.next()) |config| {
        if (!p.within(config.dir, from)) continue;
        var paths = std.mem.reverseIterator(config.paths);
        while (paths.next()) |root| if (try c.candidate(root, name, &.{suffix})) |v| return a.dupe([]const u8, &.{v});
    }
    return &.{};
}
pub const extensions = &[_][]const u8{".nim"};
