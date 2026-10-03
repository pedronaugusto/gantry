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
pub fn recover(a: std.mem.Allocator, source: []const u8) !types.Recovery {
    const ts = try l.lex(.python, a, source);
    return recoverTokens(a, ts);
}
pub fn recoverTokens(a: std.mem.Allocator, ts: []const l.Token) !types.Recovery {
    var out: std.ArrayList(Spec) = .empty;
    var unsupported: std.ArrayList(types.UnsupportedReference) = .empty;
    const loaders = l.compact(try a.dupe(l.Token, ts));
    for (loaders, 0..) |token, i| {
        // Recognize exact loader spellings, without resolving bindings or aliases.
        if (i > 0 and loaders[i - 1].is(".")) continue;
        if (token.is("importlib") and i + 3 < loaders.len and loaders[i + 1].is(".") and loaders[i + 2].is("import_module") and loaders[i + 3].is("("))
            try unsupported.append(a, .{ .offset = token.offset, .expression = .python_importlib });
        if (token.is("__import__") and i + 1 < loaders.len and loaders[i + 1].is("("))
            try unsupported.append(a, .{ .offset = token.offset, .expression = .python_import });
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
            if (base.len > 0) try out.append(a, .{ .name = base, .offset = t.offset, .form = .python, .python_base = true });
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
                try out.append(a, .{ .name = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ base, separator, child }), .offset = t.offset, .form = .python });
                j += 1;
                if (j < ts.len and ts[j].is("as")) j = @min(j + 2, ts.len);
                if (j < ts.len and !ts[j].is(",") and !ts[j].is(")") and !ts[j].is("\\") and ts[j].kind != .newline) break;
            }
        } else {
            while (j < ts.len) {
                const name = try module(a, ts, &j);
                if (name.len == 0) break;
                try out.append(a, .{ .name = name, .offset = t.offset, .form = .python });
                if (j < ts.len and ts[j].is("as")) j = @min(j + 2, ts.len);
                if (j >= ts.len or !ts[j].is(",")) break;
                j += 1;
            }
        }
        i = j -| 1;
    }
    return .{ .specs = try out.toOwnedSlice(a), .unsupported = try unsupported.toOwnedSlice(a) };
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
