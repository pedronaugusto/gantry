const std = @import("std");
const l = @import("../lexer.zig");
fn module(a: std.mem.Allocator, ts: []const l.Token, pos: *usize) ![]const u8 {
    var name: std.ArrayList(u8) = .empty;
    while (pos.* < ts.len and (ts[pos.*].kind == .word or ts[pos.*].is("."))) : (pos.* += 1) {
        if (ts[pos.*].is("import") or ts[pos.*].is("as")) break;
        try name.appendSlice(a, ts[pos.*].text);
    }
    return name.toOwnedSlice(a);
}
const types = @import("../types.zig");
const Spec = types.Spec;
/// The token stream recovery reads; `seen` observes it as it grows.
pub fn lex(a: std.mem.Allocator, source: []const u8, seen: ?l.Observer) ![]const l.Token {
    return l.lexSeen(.python, a, source, seen);
}
pub fn recover(a: std.mem.Allocator, source: []const u8) !types.Recovery {
    return recoverTokens(a, source, try lex(a, source, null));
}
pub fn recoverTokens(a: std.mem.Allocator, source: []const u8, ts: []const l.Token) !types.Recovery {
    var out: std.ArrayList(Spec) = .empty;
    var unsupported: std.ArrayList(types.UnsupportedReference) = .empty;
    // Most files never spell it: their blocks are not looked for.
    const checking = if (std.mem.find(u8, source, "TYPE_CHECKING") != null) try typeChecking(a, source, ts) else &.{};
    // Loader calls are read across line breaks, as if the stream had none.
    var previous: ?l.Token = null;
    for (ts, 0..) |token, i| {
        if (token.kind == .newline) continue;
        defer previous = token;
        // Recognize exact loader spellings, without resolving bindings or aliases.
        if (previous != null and previous.?.is(".")) continue;
        const importlib = token.is("importlib");
        if (!importlib and !token.is("__import__")) continue;
        // Enough for `.import_module(".x", package="p")`.
        var ahead: [10]l.Token = undefined;
        var n: usize = 0;
        for (ts[i + 1 ..]) |next| if (next.kind != .newline) {
            ahead[n] = next;
            n += 1;
            if (n == ahead.len) break;
        };
        const call = if (importlib and n >= 3 and ahead[0].is(".") and ahead[1].is("import_module") and ahead[2].is("("))
            ahead[3..n]
        else if (!importlib and n >= 1 and ahead[0].is("("))
            ahead[1..n]
        else
            continue;
        if (try loaded(a, call, importlib)) |name| {
            try out.append(a, .{ .name = name, .offset = token.offset, .form = .python, .kind = if (inside(checking, token.offset)) .type_only else .dynamic });
        } else try unsupported.append(a, .{ .offset = token.offset, .expression = if (importlib) .python_importlib else .python_import });
    }
    var i: usize = 0;
    while (i < ts.len) : (i += 1) {
        const t = ts[i];
        if (!t.is("from") and !t.is("import")) continue;
        // Keywords are statements only, never attributes.
        if (i > 0 and ts[i - 1].is(".")) continue;
        var j = i + 1;
        if (t.is("from")) {
            const base = try module(a, ts, &j);
            if (j >= ts.len or !ts[j].is("import")) continue;
            const base_index = out.items.len;
            const kind: types.Kind = if (inside(checking, t.offset)) .type_only else .import;
            if (base.len > 0) try out.append(a, .{ .name = base, .offset = t.offset, .form = .python, .python_base = true, .kind = kind });
            j += 1;
            if (j < ts.len and ts[j].is("*") and base.len > 0) out.items[base_index].star = true;
            var parens: usize = 0;
            while (j < ts.len) {
                if (ts[j].is("(")) {
                    parens += 1;
                    j += 1;
                    continue;
                }
                if (ts[j].is(")")) {
                    if (parens > 0) parens -= 1;
                    j += 1;
                    continue;
                }
                if (ts[j].kind == .newline) {
                    if (parens == 0) break;
                    j += 1;
                    continue;
                }
                if (ts[j].is("\\") or ts[j].is(",")) {
                    j += 1;
                    continue;
                }
                if (ts[j].kind != .word) break;
                const child = ts[j].text;
                const separator = if (base.len == 0 or std.mem.endsWith(u8, base, ".")) "" else ".";
                try out.append(a, .{ .name = try a.print("{s}{s}{s}", .{ base, separator, child }), .offset = t.offset, .form = .python, .kind = kind });
                j += 1;
                if (j < ts.len and ts[j].is("as")) j = @min(j + 2, ts.len);
                if (j < ts.len and !ts[j].is(",") and !ts[j].is(")") and !ts[j].is("\\") and ts[j].kind != .newline) break;
            }
        } else {
            while (j < ts.len) {
                const name = try module(a, ts, &j);
                if (name.len == 0) break;
                try out.append(a, .{ .name = name, .offset = t.offset, .form = .python, .kind = if (inside(checking, t.offset)) .type_only else .import });
                if (j < ts.len and ts[j].is("as")) j = @min(j + 2, ts.len);
                if (j >= ts.len or !ts[j].is(",")) break;
                j += 1;
            }
        }
        i = j -| 1;
    }
    return .{ .specs = try out.toOwnedSlice(a), .unsupported = try unsupported.toOwnedSlice(a) };
}

/// The module a loader call with literal arguments imports:
/// `import_module("a.b")`, `import_module(".b", "a")` or with `package="a"`,
/// and `__import__("a.b")`. A relative name resolves against its package
/// as `importlib` does. Null for any other argument.
fn loaded(a: std.mem.Allocator, args: []const l.Token, importlib: bool) !?[]const u8 {
    if (args.len < 2 or args[0].kind != .string) return null;
    const name = l.decode(a, args[0].text) catch return null;
    if (name.len == 0) return null;
    if (!args[1].is(")") and !args[1].is(",")) return null;
    // `__import__` imports its first argument whatever follows; its
    // `level` is not read, so a relative name is not resolved.
    if (!importlib) return if (name[0] == '.') null else name;
    var package: ?[]const u8 = null;
    if (args[1].is(",")) {
        var k: usize = 2;
        if (k + 1 < args.len and args[k].is("package") and args[k + 1].is("=")) k += 2;
        if (k + 1 >= args.len or args[k].kind != .string or !args[k + 1].is(")")) return null;
        package = l.decode(a, args[k].text) catch return null;
    }
    if (name[0] != '.') return name;
    // A relative name needs its package, as `importlib` does.
    const base = package orelse return null;
    var dots: usize = 0;
    while (dots < name.len and name[dots] == '.') : (dots += 1) {}
    var anchor = base;
    for (1..dots) |_| anchor = anchor[0 .. std.mem.findScalarLast(u8, anchor, '.') orelse return null];
    if (anchor.len == 0) return null;
    return if (dots == name.len) anchor else try a.print("{s}.{s}", .{ anchor, name[dots..] });
}

/// Byte ranges of `if TYPE_CHECKING:` bodies, `typing.TYPE_CHECKING` or any
/// `name.TYPE_CHECKING` included, as import-linter's
/// `exclude_type_checking_imports` reads them: from the `if` to the first
/// later line indented no deeper, which ends it (an `else` or `elif` too).
/// Nested blocks stay inside.
const Range = struct { start: usize, end: usize };
fn typeChecking(a: std.mem.Allocator, source: []const u8, ts: []const l.Token) ![]const Range {
    var ranges: std.ArrayList(Range) = .empty;
    var open: ?struct { start: usize, indent: usize } = null;
    var depth: usize = 0;
    var line_start = true;
    for (ts, 0..) |t, i| {
        if (t.kind == .newline) {
            // A logical line ends outside brackets and without a `\`.
            if (depth == 0 and !(i > 0 and ts[i - 1].is("\\"))) line_start = true;
            continue;
        }
        if (line_start) {
            line_start = false;
            const begin = if (std.mem.findScalarLast(u8, source[0..t.offset], '\n')) |nl| nl + 1 else 0;
            const indent = t.offset - begin;
            if (open) |block| if (indent <= block.indent) {
                try ranges.append(a, .{ .start = block.start, .end = t.offset });
                open = null;
            };
            if (open == null and t.is("if") and checkingTest(ts[i + 1 ..])) open = .{ .start = t.offset, .indent = indent };
        }
        if (t.is("(") or t.is("[") or t.is("{")) depth += 1;
        if ((t.is(")") or t.is("]") or t.is("}")) and depth > 0) depth -= 1;
    }
    if (open) |block| try ranges.append(a, .{ .start = block.start, .end = source.len });
    return ranges.toOwnedSlice(a);
}
/// `TYPE_CHECKING:` or `name.TYPE_CHECKING:` after `if`.
fn checkingTest(rest: []const l.Token) bool {
    if (rest.len >= 2 and rest[0].is("TYPE_CHECKING") and rest[1].is(":")) return true;
    return rest.len >= 4 and rest[0].kind == .word and rest[1].is(".") and rest[2].is("TYPE_CHECKING") and rest[3].is(":");
}
fn inside(ranges: []const Range, offset: usize) bool {
    for (ranges) |range| if (offset >= range.start and offset < range.end) return true;
    return false;
}

const p = @import("../path.zig");
pub fn resolve(c: anytype, from: []const u8, spec: Spec) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const a = c.allocator;
    const dir = p.dir(from);
    const name = spec.name;
    var dots: usize = 0;
    while (dots < name.len and name[dots] == '.') : (dots += 1) {}
    const rel = try std.mem.replaceOwned(u8, a, name[dots..], ".", "/");
    if (dots > 0) {
        var root = dir;
        var n: usize = 1;
        while (n < dots) : (n += 1) {
            if (root.len == 0) return &.{};
            root = p.dir(root);
        }
        var boundary: []const u8 = "";
        for (c.python_roots) |search| if (p.within(search, dir) and search.len > boundary.len) {
            boundary = search;
        };
        if (!p.within(boundary, root) or std.mem.eql(u8, boundary, root)) return &.{};
        try c.python(&out, root, rel);
        if (c.python_initializers == .modulefinder and rel.len == 0 and out.items.len > 0) {
            var parent = p.dir(root);
            while (parent.len > boundary.len and p.within(boundary, parent)) : (parent = p.dir(parent)) {
                if (try c.candidate("", parent, &.{"/__init__.py"})) |init| try out.append(a, init);
            }
        }
    } else {
        for (c.python_roots) |root| {
            try c.python(&out, root, rel);
            if (out.items.len > 0) break;
        }
    }
    if (spec.star and out.items.len > 0) if (c.python_reexports.get(out.items[0])) |exports| {
        try out.appendSlice(a, exports);
    };
    return out.toOwnedSlice(a);
}
pub const extensions = &[_][]const u8{".py"};
