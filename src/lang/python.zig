const std = @import("std");
const l = @import("../lexer.zig");
const Spec = @import("../types.zig").Spec;
fn module(a: std.mem.Allocator, ts: []const l.Token, pos: *usize) ![]const u8 {
    var name: std.ArrayList(u8) = .empty;
    while (pos.* < ts.len and (ts[pos.*].kind == .word or ts[pos.*].is("."))) : (pos.* += 1) {
        if (ts[pos.*].is("import") or ts[pos.*].is("as")) break;
        try name.appendSlice(a, ts[pos.*].text);
    }
    return name.toOwnedSlice(a);
}
pub fn imports(a: std.mem.Allocator, source: []const u8) ![]const Spec {
    const ts = try l.lex(.python, a, source);
    var out: std.ArrayList(Spec) = .empty;
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
            if (base.len > 0) try out.append(a, .{ .name = base, .offset = t.offset, .form = .python });
            j += 1;
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
    return out.toOwnedSlice(a);
}
