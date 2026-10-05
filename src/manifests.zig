//! Dependency declarations, not lockfiles or package-manager evaluation.
const gradle_module = @import("manifests/gradle.zig");
const maven_module = @import("manifests/maven.zig");
const nimble_module = @import("manifests/nimble.zig");
const std = @import("std");
const l = @import("lexer.zig");
const t = @import("types.zig");
const p = @import("path.zig");
/// The manifest file names `parse` reads, each the whole base name of a path.
pub const names = [_][]const u8{ "build.zig.zon", "package.json", "Cargo.toml", "go.mod", "pyproject.toml", "pom.xml", "build.gradle", "build.gradle.kts" };
/// The manifest extensions `parse` reads, for manifests named after their package.
pub const extensions = [_][]const u8{".nimble"};
/// Whether `path`'s base name is one of `names` or ends in one of `extensions`.
pub fn supported(path: []const u8) bool {
    const name = p.base(path);
    for (names) |s| if (std.mem.eql(u8, s, name)) return true;
    for (extensions) |s| if (name.len > s.len and std.mem.endsWith(u8, name, s)) return true;
    return false;
}
/// What a manifest declares, and the declarations it spells in a form that
/// is not read: each record's offset starts the construct.
pub const Declarations = struct {
    dependencies: []const t.Dependency,
    unsupported: []const t.UnsupportedReference,
};
/// a must be an arena: parser workspaces and strings share its lifetime.
/// Returned declarations borrow text or that arena; parse does not own either.
/// ZON validates the whole document and reads only the root struct dependencies.
/// Invalid ZON or dependency shapes return InvalidManifest, with no partial result.
pub fn parse(a: std.mem.Allocator, path: []const u8, text: []const u8) ![]const t.Dependency {
    return (try read(a, path, text)).dependencies;
}
/// `parse`, keeping the declarations it cannot read (records without a path).
pub fn read(a: std.mem.Allocator, path: []const u8, text: []const u8) !Declarations {
    var out: std.ArrayList(t.Dependency) = .empty;
    var unsupported: std.ArrayList(t.UnsupportedReference) = .empty;
    const name = p.base(path);
    if (std.mem.eql(u8, name, "package.json")) try json(a, path, text, &out) else if (std.mem.eql(u8, name, "build.zig.zon")) try zon(a, path, text, &out) else if (std.mem.eql(u8, name, "go.mod")) try goMod(a, path, text, &out) else if (std.mem.eql(u8, name, "Cargo.toml") or std.mem.eql(u8, name, "pyproject.toml")) try toml(a, path, text, &out) else if (supported(path) and std.mem.endsWith(u8, name, ".nimble")) try nimble_module.parse(a, path, text, &out, &unsupported) else if (std.mem.eql(u8, name, "pom.xml")) try maven_module.parse(a, path, text, &out, &unsupported) else if (std.mem.eql(u8, name, "build.gradle") or std.mem.eql(u8, name, "build.gradle.kts")) try gradle_module.parse(a, path, text, &out, &unsupported) else return error.UnsupportedManifest;
    return .{ .dependencies = try out.toOwnedSlice(a), .unsupported = try unsupported.toOwnedSlice(a) };
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
            try out.append(a, .{ .manifest = path, .name = entry.key_ptr.*, .requirement = requirement, .source = if (place(requirement)) requirement else "", .group = group, .origin = npmOrigin(requirement) });
        }
    }
}
/// npm's specifier forms (`npm help package-spec`): a version or range or
/// `npm:` alias is the registry's; anything else names a place.
fn npmOrigin(s: []const u8) t.Dependency.Origin {
    if (std.mem.startsWith(u8, s, "workspace:")) return .workspace;
    if (std.mem.startsWith(u8, s, "npm:")) return .registry;
    for ([_][]const u8{ "file:", "link:", "./", "../", "/", "~/" }) |prefix| if (std.mem.startsWith(u8, s, prefix)) return .local;
    if (std.mem.find(u8, s, "://") != null or std.mem.startsWith(u8, s, "git") or std.mem.findScalar(u8, s, ':') != null) return .remote;
    // `owner/repo`, GitHub's shorthand
    if (std.mem.findScalar(u8, s, '/') != null) return .remote;
    return .registry;
}
fn place(s: []const u8) bool {
    return std.mem.findScalar(u8, s, '/') != null or std.mem.startsWith(u8, s, "git") or std.mem.startsWith(u8, s, "file:") or std.mem.startsWith(u8, s, "github:") or std.mem.startsWith(u8, s, "workspace:");
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
            .origin = if (url != null) .remote else if (local != null) .local else .registry,
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
        const comment_at = std.mem.find(u8, line, "//");
        const clean = line[0 .. comment_at orelse line.len];
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
        // `// indirect` marks a module only other modules import, as Go
        // reads the comment: the word alone or before a `;`.
        const indirect = if (comment_at) |at| blk: {
            const comment = std.mem.trim(u8, line[at + 2 ..], " \t\r");
            break :blk std.mem.eql(u8, comment, "indirect") or std.mem.startsWith(u8, comment, "indirect;");
        } else false;
        try out.append(a, .{ .manifest = path, .name = std.mem.trim(u8, name, "\"`"), .source = std.mem.trim(u8, name, "\"`"), .requirement = version, .group = if (indirect) "indirect" else "require", .origin = .remote });
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
            const sub = std.mem.findScalar(u8, tail, '.');
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
                    if (std.mem.eql(u8, key, "path") or std.mem.eql(u8, key, "git")) {
                        entry.?.source = try string(a, text, value[0]);
                        entry.?.origin = if (std.mem.eql(u8, key, "path")) .local else .remote;
                    }
                } else if (std.mem.eql(u8, key, "workspace") and value[0].is("true")) entry.?.origin = .workspace;
            } else {
                var dep: t.Dependency = .{ .manifest = path, .name = key, .group = group };
                if (value[0].kind == .string) dep.requirement = try string(a, text, value[0]) else if (value[0].is("{")) {
                    for (value, 0..) |token, j| {
                        if (j + 2 >= value.len or !value[j + 1].is("=")) continue;
                        if (value[j + 2].kind == .string) {
                            const v = try string(a, text, value[j + 2]);
                            if (token.is("version")) dep.requirement = v;
                            if (token.is("path") or token.is("git")) {
                                dep.source = v;
                                dep.origin = if (token.is("path")) .local else .remote;
                            }
                        } else if (token.is("workspace") and value[j + 2].is("true")) {
                            dep.source = "workspace";
                            dep.origin = .workspace;
                        }
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
                    if (token.is("git") or token.is("path") or token.is("url")) {
                        dep.source = v;
                        dep.origin = if (token.is("path")) .local else .remote;
                    }
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
    const url = std.mem.find(u8, raw, " @ ");
    const source = if (url) |u| std.mem.trim(u8, raw[u + 3 .. std.mem.findScalarPos(u8, raw, u + 3, ';') orelse raw.len], " ") else "";
    const origin: t.Dependency.Origin = if (source.len == 0) .registry else if (std.mem.startsWith(u8, source, "file:")) .local else .remote;
    try out.append(a, .{ .manifest = path, .name = raw[0..end], .requirement = raw, .source = source, .group = group, .origin = origin });
}

fn string(a: std.mem.Allocator, text: []const u8, token: l.Token) ![]const u8 {
    return if (text[token.offset] == '\'') token.text else try l.decode(a, token.text);
}
