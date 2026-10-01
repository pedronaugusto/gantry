//! Dependency declarations, not lockfiles or package-manager evaluation.
const std = @import("std");
const l = @import("lexer.zig");
const t = @import("types.zig");
const p = @import("path.zig");
pub fn supported(path: []const u8) bool {
    const name = p.base(path);
    for ([_][]const u8{ "build.zig.zon", "package.json", "Cargo.toml", "go.mod", "pyproject.toml" }) |s| if (std.mem.eql(u8, s, name)) return true;
    return false;
}
/// a must be an arena: parser workspaces and strings share its lifetime.
/// Returned declarations borrow text or that arena; parse does not own either.
/// ZON validates the whole document and reads only the root struct dependencies.
/// Invalid ZON or dependency shapes return InvalidManifest, with no partial result.
pub fn parse(a: std.mem.Allocator, path: []const u8, text: []const u8) ![]const t.Dependency {
    var out: std.ArrayList(t.Dependency) = .empty;
    const name = p.base(path);
    if (std.mem.eql(u8, name, "package.json")) try json(a, path, text, &out) else if (std.mem.eql(u8, name, "build.zig.zon")) try zon(a, path, text, &out) else if (std.mem.eql(u8, name, "go.mod")) try goMod(a, path, text, &out) else if (std.mem.eql(u8, name, "Cargo.toml") or std.mem.eql(u8, name, "pyproject.toml")) try toml(a, path, text, &out) else return error.UnsupportedManifest;
    return out.toOwnedSlice(a);
}
fn json(a: std.mem.Allocator, path: []const u8, text: []const u8, out: *std.ArrayList(t.Dependency)) !void {
    const value = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidManifest,
    };
    if (value != .object) return error.InvalidManifest;
    for ([_][]const u8{ "dependencies", "devDependencies", "peerDependencies", "optionalDependencies" }) |group| {
        const deps = value.object.get(group) orelse continue;
        if (deps != .object) return error.InvalidManifest;
        var it = deps.object.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != .string) return error.InvalidManifest;
            const requirement = entry.value_ptr.string;
            try out.append(a, .{ .manifest = path, .name = entry.key_ptr.*, .requirement = requirement, .source = if (place(requirement)) requirement else "", .group = group });
        }
    }
}
fn place(s: []const u8) bool {
    return std.mem.indexOfScalar(u8, s, '/') != null or std.mem.startsWith(u8, s, "git") or std.mem.startsWith(u8, s, "file:") or std.mem.startsWith(u8, s, "github:") or std.mem.startsWith(u8, s, "workspace:");
}
fn zon(a: std.mem.Allocator, path: []const u8, text: []const u8, out: *std.ArrayList(t.Dependency)) !void {
    const source = try a.dupeZ(u8, text);
    defer a.free(source);
    var ast = try std.zig.Ast.parse(a, source, .zon);
    defer ast.deinit(a);
    var zoir = try std.zig.ZonGen.generate(a, ast, .{});
    defer zoir.deinit(a);
    if (zoir.hasCompileErrors()) return error.InvalidManifest;

    const root = std.zig.Zoir.Node.Index.root.get(zoir);
    const deps = (try zonField(zoir, root, "dependencies")) orelse return;
    if (deps == .empty_literal) return;
    if (deps != .struct_literal) return error.InvalidManifest;
    for (deps.struct_literal.names, 0..) |name, i| {
        const value = deps.struct_literal.vals.at(@intCast(i)).get(zoir);
        const url = try zonString(zoir, value, "url");
        const local = try zonString(zoir, value, "path");
        const hash = try zonString(zoir, value, "hash");
        if (url != null and local != null) return error.InvalidManifest;
        if (try zonField(zoir, value, "lazy")) |lazy| {
            if (lazy != .true and lazy != .false) return error.InvalidManifest;
        }
        try out.append(a, .{
            .manifest = path,
            .name = try a.dupe(u8, name.get(zoir)),
            .source = try a.dupe(u8, url orelse local orelse ""),
            .requirement = try a.dupe(u8, hash orelse ""),
        });
    }
}
fn zonField(zoir: std.zig.Zoir, node: std.zig.Zoir.Node, name: []const u8) error{InvalidManifest}!?std.zig.Zoir.Node {
    if (node == .empty_literal) return null;
    if (node != .struct_literal) return error.InvalidManifest;
    for (node.struct_literal.names, 0..) |field, i| {
        if (std.mem.eql(u8, field.get(zoir), name)) return node.struct_literal.vals.at(@intCast(i)).get(zoir);
    }
    return null;
}
fn zonString(zoir: std.zig.Zoir, node: std.zig.Zoir.Node, name: []const u8) error{InvalidManifest}!?[]const u8 {
    const value = (try zonField(zoir, node, name)) orelse return null;
    if (value != .string_literal) return error.InvalidManifest;
    return value.string_literal;
}
pub fn modulePath(text: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var words = std.mem.tokenizeAny(u8, line, " \t\r");
        const first = words.next() orelse continue;
        if (!std.mem.eql(u8, first, "module")) continue;
        const name = words.next() orelse return null;
        return std.mem.trim(u8, name, "\"`");
    }
    return null;
}
fn goMod(a: std.mem.Allocator, path: []const u8, text: []const u8, out: *std.ArrayList(t.Dependency)) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var block = false;
    while (lines.next()) |line| {
        const clean = line[0 .. std.mem.indexOf(u8, line, "//") orelse line.len];
        var words = std.mem.tokenizeAny(u8, clean, " \t\r");
        var name = words.next() orelse continue;
        if (std.mem.eql(u8, name, "require")) {
            name = words.next() orelse return error.InvalidManifest;
            if (std.mem.eql(u8, name, "(")) {
                block = true;
                continue;
            }
        } else if (!block) continue;
        if (std.mem.eql(u8, name, ")")) {
            block = false;
            continue;
        }
        const version = words.next() orelse return error.InvalidManifest;
        try out.append(a, .{ .manifest = path, .name = std.mem.trim(u8, name, "\"`"), .source = std.mem.trim(u8, name, "\"`"), .requirement = version, .group = "require" });
    }
    if (block) return error.InvalidManifest;
}
fn toml(a: std.mem.Allocator, path: []const u8, text: []const u8, out: *std.ArrayList(t.Dependency)) !void {
    const ts = try l.lex(.python, a, text);
    const cargo = std.mem.eql(u8, p.base(path), "Cargo.toml");
    var group: []const u8 = "";
    var i: usize = 0;
    while (i < ts.len) {
        if (ts[i].kind == .newline) {
            i += 1;
            continue;
        }
        if (ts[i].is("[")) {
            var header: std.ArrayList(u8) = .empty;
            i += 1;
            while (i < ts.len and !ts[i].is("]")) : (i += 1) {
                if (ts[i].kind == .newline) return error.InvalidManifest;
                try header.appendSlice(a, ts[i].text);
            }
            if (i == ts.len) return error.InvalidManifest;
            group = try header.toOwnedSlice(a);
            i += 1;
            continue;
        }
        const start = i;
        var eq: ?usize = null;
        var depth: usize = 0;
        while (i < ts.len) : (i += 1) {
            if (ts[i].kind == .newline and depth == 0) break;
            if (ts[i].is("=") and eq == null) eq = i;
            if (ts[i].is("[") or ts[i].is("{")) depth += 1;
            if (ts[i].is("]") or ts[i].is("}")) {
                if (depth == 0) return error.InvalidManifest;
                depth -= 1;
            }
        }
        if (depth != 0) return error.InvalidManifest;
        const equal = eq orelse continue;
        if (equal + 1 >= i) continue;
        const key = if (equal == start + 1 and ts[start].kind == .string) ts[start].text else std.mem.trim(u8, text[ts[start].offset..ts[equal].offset], " \t");
        const value = ts[equal + 1 .. i];
        if (cargo) {
            const dep_at = dependencyTable(group) orelse continue;
            const tail = group[dep_at..];
            const sub = std.mem.indexOfScalar(u8, tail, '.');
            if (sub) |dot| {
                const dep_name = tail[dot + 1 ..];
                var entry: ?*t.Dependency = null;
                for (out.items) |*item| if (std.mem.eql(u8, item.group, group) and std.mem.eql(u8, item.name, dep_name)) {
                    entry = item;
                    break;
                };
                if (entry == null) {
                    try out.append(a, .{ .manifest = path, .name = dep_name, .group = group });
                    entry = &out.items[out.items.len - 1];
                }
                if (value[0].kind == .string) {
                    if (std.mem.eql(u8, key, "version")) entry.?.requirement = try string(a, text, value[0]);
                    if (std.mem.eql(u8, key, "path") or std.mem.eql(u8, key, "git")) entry.?.source = try string(a, text, value[0]);
                }
            } else {
                var dep: t.Dependency = .{ .manifest = path, .name = key, .group = group };
                if (value[0].kind == .string) dep.requirement = try string(a, text, value[0]) else if (value[0].is("{")) {
                    for (value, 0..) |token, j| {
                        if (j + 2 >= value.len or !value[j + 1].is("=")) continue;
                        if (value[j + 2].kind == .string) {
                            const v = try string(a, text, value[j + 2]);
                            if (token.is("version")) dep.requirement = v;
                            if (token.is("path") or token.is("git")) dep.source = v;
                        } else if (token.is("workspace") and value[j + 2].is("true")) dep.source = "workspace";
                    }
                } else return error.InvalidManifest;
                try out.append(a, dep);
            }
        } else if ((std.mem.eql(u8, group, "project") and std.mem.eql(u8, key, "dependencies")) or std.mem.eql(u8, group, "project.optional-dependencies") or std.mem.eql(u8, group, "dependency-groups")) {
            if (!value[0].is("[")) return error.InvalidManifest;
            const label = try std.fmt.allocPrint(a, "{s}.{s}", .{ group, key });
            var braces: usize = 0;
            for (value) |token| {
                if (token.is("{")) braces += 1;
                if (token.is("}")) braces -= 1;
                if (braces == 0 and token.kind == .string) try pythonDep(a, path, label, try string(a, text, token), out);
            }
        } else if (std.mem.startsWith(u8, group, "tool.poetry.") and std.mem.endsWith(u8, group, "dependencies") and !std.mem.eql(u8, key, "python")) {
            var dep: t.Dependency = .{ .manifest = path, .name = key, .group = group };
            if (value[0].kind == .string) dep.requirement = try string(a, text, value[0]) else for (value, 0..) |token, j| {
                if (j + 2 < value.len and value[j + 1].is("=") and value[j + 2].kind == .string) {
                    const v = try string(a, text, value[j + 2]);
                    if (token.is("version")) dep.requirement = v;
                    if (token.is("git") or token.is("path") or token.is("url")) dep.source = v;
                }
            }
            try out.append(a, dep);
        }
    }
}
fn dependencyTable(group: []const u8) ?usize {
    var start: usize = 0;
    var parts = std.mem.splitScalar(u8, group, '.');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "dependencies") or std.mem.eql(u8, part, "dev-dependencies") or std.mem.eql(u8, part, "build-dependencies")) return start;
        start += part.len + 1;
    }
    return null;
}
fn pythonDep(a: std.mem.Allocator, path: []const u8, group: []const u8, requirement: []const u8, out: *std.ArrayList(t.Dependency)) !void {
    const raw = std.mem.trim(u8, requirement, " \t");
    const end = std.mem.indexOfAny(u8, raw, "<>=!~[; @(") orelse raw.len;
    if (end == 0) return error.InvalidManifest;
    const url = std.mem.indexOf(u8, raw, " @ ");
    const source = if (url) |u| std.mem.trim(u8, raw[u + 3 .. std.mem.indexOfScalarPos(u8, raw, u + 3, ';') orelse raw.len], " ") else "";
    try out.append(a, .{ .manifest = path, .name = raw[0..end], .requirement = raw, .source = source, .group = group });
}

fn string(a: std.mem.Allocator, text: []const u8, token: l.Token) ![]const u8 {
    return if (text[token.offset] == '\'') token.text else try l.decode(a, token.text);
}
