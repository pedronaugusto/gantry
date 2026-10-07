//! `pom.xml` dependencies: the project's own `<dependencies>`, read as XML.
const std = @import("std");
const t = @import("../types.zig");

const Field = enum { groupId, artifactId, version, scope, optional, systemPath };
const Declared = struct { offset: usize, fields: std.EnumArray(Field, []const u8) = .initFill("") };

/// Each `project/dependencies/dependency` with its `groupId:artifactId` name,
/// `version` requirement and `scope` group (`compile` when absent); an
/// `<optional>true</optional>` dependency's group gains `,optional`
/// (`compile,optional`). A
/// `${property}` resolves through this file's literal `<properties>` and its
/// project and parent coordinates, as Maven interpolates them; a dependency
/// that names anything else is unsupported and declares nothing. Managed
/// versions, profiles and plugin dependencies are not declarations here.
pub fn parse(a: std.mem.Allocator, path: []const u8, text: []const u8, out: *std.ArrayList(t.Dependency), unsupported: *std.ArrayList(t.UnsupportedReference)) error{ InvalidManifest, InvalidEscape, OutOfMemory }!void {
    var stack: std.ArrayList([]const u8) = .empty;
    var content: std.ArrayList(u8) = .empty;
    var properties: std.StringHashMapUnmanaged([]const u8) = .empty;
    var declared: std.ArrayList(Declared) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] != '<') {
            const end = std.mem.findScalarPos(u8, text, i, '<') orelse text.len;
            try entities(a, text[i..end], &content);
            i = end;
            continue;
        }
        if (std.mem.startsWith(u8, text[i..], "<!--")) {
            i = (std.mem.findPos(u8, text, i + 4, "-->") orelse return error.InvalidManifest) + 3;
        } else if (std.mem.startsWith(u8, text[i..], "<![CDATA[")) {
            const end = std.mem.findPos(u8, text, i + 9, "]]>") orelse return error.InvalidManifest;
            try content.appendSlice(a, text[i + 9 .. end]);
            i = end + 3;
        } else if (std.mem.startsWith(u8, text[i..], "<?")) {
            i = (std.mem.findPos(u8, text, i + 2, "?>") orelse return error.InvalidManifest) + 2;
        } else if (std.mem.startsWith(u8, text[i..], "<!")) {
            i = (std.mem.findScalarPos(u8, text, i + 2, '>') orelse return error.InvalidManifest) + 1;
        } else if (std.mem.startsWith(u8, text[i..], "</")) {
            const end = std.mem.findScalarPos(u8, text, i + 2, '>') orelse return error.InvalidManifest;
            const name = std.mem.trim(u8, text[i + 2 .. end], " \t\r\n");
            const open = stack.pop() orelse return error.InvalidManifest;
            if (!std.mem.eql(u8, open, name)) return error.InvalidManifest;
            const value = std.mem.trim(u8, content.items, " \t\r\n");
            const in = stack.items;
            if (in.len == 2 and std.mem.eql(u8, in[0], "project") and std.mem.eql(u8, in[1], "properties")) {
                try properties.put(a, name, try a.dupe(u8, value));
            } else if (in.len == 1 and std.mem.eql(u8, in[0], "project") and (std.mem.eql(u8, name, "version") or std.mem.eql(u8, name, "groupId") or std.mem.eql(u8, name, "artifactId"))) {
                try properties.put(a, try a.print("project.{s}", .{name}), try a.dupe(u8, value));
            } else if (in.len == 2 and std.mem.eql(u8, in[0], "project") and std.mem.eql(u8, in[1], "parent") and (std.mem.eql(u8, name, "version") or std.mem.eql(u8, name, "groupId"))) {
                try properties.put(a, try a.print("project.parent.{s}", .{name}), try a.dupe(u8, value));
            } else if (in.len == 3 and dependency(in)) {
                if (std.meta.stringToEnum(Field, name)) |field| declared.items[declared.items.len - 1].fields.set(field, try a.dupe(u8, value));
            }
            content.clearRetainingCapacity();
            i = end + 1;
        } else {
            var end = i + 1;
            var quote: u8 = 0;
            while (end < text.len and (quote != 0 or text[end] != '>')) : (end += 1) {
                if (quote == 0 and (text[end] == '"' or text[end] == '\'')) quote = text[end] else if (text[end] == quote) quote = 0;
            }
            if (end == text.len) return error.InvalidManifest;
            const closed = text[end - 1] == '/';
            const tag = text[i + 1 .. if (closed) end - 1 else end];
            const name = tag[0 .. std.mem.findAny(u8, tag, " \t\r\n") orelse tag.len];
            if (name.len == 0) return error.InvalidManifest;
            if (!closed) {
                if (stack.items.len == 2 and std.mem.eql(u8, name, "dependency") and std.mem.eql(u8, stack.items[0], "project") and std.mem.eql(u8, stack.items[1], "dependencies")) try declared.append(a, .{ .offset = i });
                try stack.append(a, name);
            }
            content.clearRetainingCapacity();
            i = end + 1;
        }
    }
    if (stack.items.len != 0) return error.InvalidManifest;
    // Maven reads `${project.version}` from the parent when the project has none.
    for ([_][]const u8{ "version", "groupId" }) |field| {
        const own = try a.print("project.{s}", .{field});
        if (properties.get(own) == null) if (properties.get(try a.print("project.parent.{s}", .{field}))) |inherited| try properties.put(a, own, inherited);
    }
    for ([_][2][]const u8{ .{ "pom.version", "project.version" }, .{ "version", "project.version" }, .{ "pom.groupId", "project.groupId" }, .{ "groupId", "project.groupId" }, .{ "parent.version", "project.parent.version" } }) |alias| {
        if (properties.get(alias[0]) == null) if (properties.get(alias[1])) |value| try properties.put(a, alias[0], value);
    }
    for ([_][]const u8{ "basedir", "project.basedir" }) |folder| if (properties.get(folder) == null) try properties.put(a, folder, ".");
    for (declared.items) |item| {
        var fields = item.fields;
        var known = true;
        for (std.enums.values(Field)) |field| {
            const value = (try interpolate(a, &properties, fields.get(field))) orelse {
                known = false;
                break;
            };
            fields.set(field, value);
        }
        if (!known) {
            try unsupported.append(a, .{ .offset = item.offset, .expression = .maven_dependency });
            continue;
        }
        if (fields.get(.groupId).len == 0 or fields.get(.artifactId).len == 0) return error.InvalidManifest;
        const scope = if (fields.get(.scope).len == 0) "compile" else fields.get(.scope);
        const optional = std.mem.eql(u8, fields.get(.optional), "true");
        const system = std.mem.eql(u8, scope, "system") and fields.get(.systemPath).len > 0;
        try out.append(a, .{
            .manifest = path,
            .name = try a.print("{s}:{s}", .{ fields.get(.groupId), fields.get(.artifactId) }),
            .requirement = fields.get(.version),
            .source = if (system) fields.get(.systemPath) else "",
            .group = if (optional) try a.print("{s},optional", .{scope}) else scope,
            .origin = if (system) .local else .registry,
        });
    }
}
fn dependency(in: []const []const u8) bool {
    return std.mem.eql(u8, in[0], "project") and std.mem.eql(u8, in[1], "dependencies") and std.mem.eql(u8, in[2], "dependency");
}
/// Null when a `${name}` stays undefined after a bounded number of rounds.
fn interpolate(a: std.mem.Allocator, properties: *const std.StringHashMapUnmanaged([]const u8), value: []const u8) !?[]const u8 {
    var current = value;
    for (0..8) |_| {
        const open = std.mem.find(u8, current, "${") orelse return current;
        const close = std.mem.findScalarPos(u8, current, open, '}') orelse return null;
        const replacement = properties.get(current[open + 2 .. close]) orelse return null;
        current = try std.mem.concat(a, u8, &.{ current[0..open], replacement, current[close + 1 ..] });
    }
    return null;
}
/// The five XML entities and character references; anything else stays as written.
fn entities(a: std.mem.Allocator, text: []const u8, out: *std.ArrayList(u8)) !void {
    var i: usize = 0;
    while (i < text.len) {
        // The longest reference these name is `&#x10FFFF;`.
        const end = if (text[i] == '&') std.mem.findScalarPos(u8, text[0..@min(text.len, i + 10)], i, ';') else null;
        const name = if (end) |e| text[i + 1 .. e] else "";
        const named: ?u8 = if (std.mem.eql(u8, name, "lt")) '<' else if (std.mem.eql(u8, name, "gt")) '>' else if (std.mem.eql(u8, name, "amp")) '&' else if (std.mem.eql(u8, name, "quot")) '"' else if (std.mem.eql(u8, name, "apos")) '\'' else null;
        if (named) |c| {
            try out.append(a, c);
            i = end.? + 1;
            continue;
        }
        if (name.len > 1 and name[0] == '#') {
            const hex = name[1] == 'x' or name[1] == 'X';
            var buffer: [4]u8 = undefined;
            if (std.fmt.parseInt(u21, name[if (hex) 2 else 1..], if (hex) 16 else 10)) |code| {
                if (std.unicode.utf8Encode(code, &buffer)) |len| {
                    try out.appendSlice(a, buffer[0..len]);
                    i = end.? + 1;
                    continue;
                } else |_| {}
            } else |_| {}
        }
        try out.append(a, text[i]);
        i += 1;
    }
}
