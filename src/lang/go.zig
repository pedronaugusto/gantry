const config_module = @import("go/config.zig");
const config = config_module;
const path_module = @import("../resolve/path.zig");
const std = @import("std");
const l = @import("../lexer.zig");
const types = @import("../types.zig");
const Spec = types.Spec;
// Go import declarations require string literals. There is no computed
// import expression to detect without adding a syntax-validation contract.
/// The token stream recovery reads; `seen` observes it as it grows.
pub fn lex(a: std.mem.Allocator, source: []const u8, seen: ?l.Observer) ![]const l.Token {
    return l.lexCompact(.go, a, source, seen);
}
pub fn recover(a: std.mem.Allocator, source: []const u8) !types.Recovery {
    return recoverTokens(a, source, try lex(a, source, null));
}
pub fn recoverTokens(a: std.mem.Allocator, source: []const u8, ts: []const l.Token) !types.Recovery {
    var out: std.ArrayList(Spec) = .empty;
    for (ts, 0..) |t, i| {
        if (!t.is("import") or i + 1 >= ts.len) continue;
        var j = i + 1;
        const block = ts[j].is("(");
        if (block) j += 1;
        while (j < ts.len and !ts[j].is(")")) : (j += 1) {
            if (ts[j].kind == .string) {
                const raw = source[ts[j].offset] == '`';
                try out.append(a, .{ .name = if (raw) ts[j].text else try l.decode(a, ts[j].text), .offset = t.offset });
                if (!block) break;
            } else if (!block and ts[j].kind != .word and !ts[j].is(".")) break;
        }
    }
    return .{ .specs = try out.toOwnedSlice(a) };
}

const p = @import("../path.zig");
pub fn resolve(c: anytype, from: []const u8, spec: Spec) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const a = c.allocator;
    const name = spec.name;
    var owner: ?config_module.Module = null;
    for (c.go_modules) |m| if (p.within(m.root, from) and (owner == null or m.root.len > owner.?.root.len)) {
        owner = m;
    };
    const m = owner orelse return &.{};
    var work: ?config.Workspace = null;
    for (c.go_workspaces) |w| if (p.within(w.root, from) and config.used(w, m.root) and (work == null or w.root.len > work.?.root.len)) {
        work = w;
    };
    var chosen: ?config.Module = null;
    for (c.go_modules) |other| {
        const eligible = std.mem.eql(u8, other.root, m.root) or (work != null and config.used(work.?, other.root));
        if (eligible and p.within(other.name, name) and (chosen == null or other.name.len > chosen.?.name.len)) chosen = other;
    }
    var version: []const u8 = "";
    var dependency: []const u8 = if (chosen) |v| v.name else "";
    for (m.requires) |req| if (p.within(req.name, name) and req.name.len >= dependency.len) {
        dependency = req.name;
        version = req.version;
    };
    // A replacement can name a local dependency even when its declaration is
    // absent from the selected manifest subset; wildcard directives are lexical.
    for (m.replacements) |r| if (p.within(r.name, name) and r.name.len > dependency.len) {
        dependency = r.name;
    };
    if (work) |w| {
        for (w.replacements) |r| if (p.within(r.name, name) and r.name.len > dependency.len) {
            dependency = r.name;
        };
        for (c.go_modules) |other| if (config.used(w, other.root)) {
            for (other.requires) |req| if (p.within(req.name, name) and req.name.len > dependency.len) {
                dependency = req.name;
                version = req.version;
            };
        };
    }
    if (chosen) |main| {
        // Workspace members (and the importing main module itself) use their
        // workspace version, regardless of requirements or replacements.
        const tail = if (name.len == main.name.len) "" else name[main.name.len + 1 ..];
        const key = try path_module.join(a, main.root, tail, "");
        for (c.go_modules) |other| if (other.root.len > main.root.len and p.within(other.root, key)) return &.{};
        if (c.packages.get(key)) |files| try out.appendSlice(a, files.items);
        return out.toOwnedSlice(a);
    }
    if (dependency.len == 0) return &.{};
    var route = config.replacement(m.replacements, dependency, version);
    if (work) |w| {
        var workspace_route: ?config.Replacement = null;
        for (c.go_modules) |other| if (config.used(w, other.root)) {
            if (config.replacement(other.replacements, dependency, version)) |r| {
                if (workspace_route) |previous| {
                    if (!std.mem.eql(u8, previous.root orelse "", r.root orelse "") and config.replacement(w.replacements, dependency, version) == null) return error.ConflictingReplacement;
                }
                workspace_route = r;
            }
        };
        route = config.replacement(w.replacements, dependency, version) orelse workspace_route;
    }
    const root = if (route) |r| r.root orelse return &.{} else if (chosen) |v| v.root else return &.{};
    const tail = if (name.len == dependency.len) "" else name[dependency.len + 1 ..];
    const key = try path_module.join(a, root, tail, "");
    for (c.go_modules) |other| if (other.root.len > root.len and p.within(other.root, key)) return &.{};
    if (c.packages.get(key)) |files| try out.appendSlice(a, files.items);
    return out.toOwnedSlice(a);
}
pub const extensions = &[_][]const u8{".go"};
