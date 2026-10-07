const std = @import("std");
const l = @import("../lexer.zig");
const types = @import("../types.zig");
const Spec = types.Spec;
/// The token stream recovery reads; `seen` observes it as it grows.
pub fn lex(arena: std.mem.Allocator, source: []const u8, seen: ?l.Observer) std.mem.Allocator.Error![]const l.Token {
    return l.lexCompact(.java, arena, source, seen);
}
pub fn recover(arena: std.mem.Allocator, source: []const u8) std.mem.Allocator.Error!types.Recovery {
    return recoverTokens(arena, source, try lex(arena, source, null));
}
/// The `package` declaration and top-level `import` declarations: single
/// types, `.*` on demand, and `static` members. Java has no computed import;
/// the class-loading calls `Class.forName(` and `.loadClass(` are unsupported.
pub fn recoverTokens(arena: std.mem.Allocator, _: []const u8, ts: []const l.Token) std.mem.Allocator.Error!types.Recovery {
    var out: std.ArrayList(Spec) = .empty;
    var unsupported: std.ArrayList(types.UnsupportedReference) = .empty;
    var package: []const u8 = "";
    var depth: usize = 0;
    var i: usize = 0;
    while (i < ts.len) : (i += 1) {
        const t = ts[i];
        if (t.is("{")) depth += 1;
        if (t.is("}")) depth -|= 1;
        if (t.is("Class") and i + 3 < ts.len and ts[i + 1].is(".") and ts[i + 2].is("forName") and ts[i + 3].is("(") and (i == 0 or !ts[i - 1].is(".")))
            try unsupported.append(arena, .{ .offset = t.offset, .expression = .java_for_name });
        if (t.is("loadClass") and i > 0 and ts[i - 1].is(".") and i + 1 < ts.len and ts[i + 1].is("("))
            try unsupported.append(arena, .{ .offset = t.offset, .expression = .java_load_class });
        if (depth != 0 or (i > 0 and ts[i - 1].is("."))) continue;
        if (t.is("package") and package.len == 0) {
            var j = i + 1;
            const name = try qualified(arena, ts, &j);
            if (name.len > 0 and j < ts.len and ts[j].is(";")) package = name;
            continue;
        }
        if (!t.is("import") or (i > 0 and !ts[i - 1].is(";") and !ts[i - 1].is("}"))) continue;
        var j = i + 1;
        const static = j < ts.len and ts[j].is("static");
        if (static) j += 1;
        var name = try qualified(arena, ts, &j);
        if (name.len == 0) continue;
        const star = j + 1 < ts.len and ts[j].is(".") and ts[j + 1].is("*");
        if (star) {
            name = try std.mem.concat(arena, u8, &.{ name, ".*" });
            j += 2;
        }
        if (j >= ts.len or !ts[j].is(";")) continue;
        try out.append(arena, .{ .name = name, .offset = t.offset, .form = if (static) .java_static else .literal, .star = star });
        i = j;
    }
    return .{ .specs = try out.toOwnedSlice(arena), .unsupported = try unsupported.toOwnedSlice(arena), .package = package };
}
/// `a.b.C`, stopping before a `.*`.
fn qualified(arena: std.mem.Allocator, ts: []const l.Token, j: *usize) ![]const u8 {
    var name: std.ArrayList(u8) = .empty;
    while (j.* < ts.len and ts[j.*].kind == .word) {
        try name.appendSlice(arena, ts[j.*].text);
        j.* += 1;
        if (j.* + 1 < ts.len and ts[j.*].is(".") and ts[j.* + 1].kind == .word) {
            try name.append(arena, '.');
            j.* += 1;
        } else break;
    }
    return name.toOwnedSlice(arena);
}

const p = @import("../path.zig");
/// Types resolve through the declared packages of selected files: `a.b.C`
/// is the file `C.java` declaring `package a.b`, and a nested or static
/// member such as `a.b.C.D` falls back to its enclosing type's file. `a.b.*`
/// is every file of package `a.b`, or the type `a.b` when there is no such
/// package: an over-approximation, since the importer uses only some of
/// them, which symbol-level dependencies would narrow. A type several
/// selected files declare resolves to each of them.
pub fn resolve(c: anytype, from: []const u8, spec: Spec) types.ResolveError![]const []const u8 {
    _ = from;
    const a = c.allocator;
    var name = spec.name;
    if (spec.star) {
        name = name[0 .. name.len - 2];
        if (spec.form != .java_static) if (c.java_packages.get(name)) |files| return a.dupe([]const u8, files.items);
    }
    var end = name.len;
    while (std.mem.findScalarLast(u8, name[0..end], '.')) |dot| : (end = dot) {
        const files = c.java_packages.get(name[0..dot]) orelse continue;
        const simple = name[dot + 1 .. end];
        var out: std.ArrayList([]const u8) = .empty;
        for (files.items) |file| {
            const base = p.base(file);
            if (std.mem.eql(u8, base[0 .. base.len - ".java".len], simple)) try out.append(a, file);
        }
        if (out.items.len > 0) return out.toOwnedSlice(a);
    }
    return &.{};
}
pub const extensions = &[_][]const u8{".java"};
