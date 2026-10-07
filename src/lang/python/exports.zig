//! A bounded lexical re-export index. Dynamic export lists stay unresolved.
const types_module = @import("../../types.zig");
const tokens_module = @import("../../tokens.zig");
const diagnostic_module = @import("../../scan/diagnostic.zig");
const std = @import("std");
const l = @import("../../lexer.zig");
const python = @import("../python.zig");
const Spec = types_module.Spec;
const Export = struct { name: []const u8, base: Spec, child: Spec };
fn top(text: []const u8, offset: usize) bool {
    return offset == 0 or text[offset - 1] == '\n';
}
fn targets(arena: std.mem.Allocator, source: []const u8, from: []const u8, ctx: anytype, ts: []const l.Token, specs: []const Spec) ![]const []const u8 {
    // No literal export list is possible without this spelling. Imports still
    // use the same recovered tokens regardless of whether exports are present.
    if (std.mem.find(u8, source, "__all__") == null) return &.{};
    var names: std.ArrayList([]const u8) = .empty;
    var exports: std.ArrayList(Export) = .empty;
    var literal = false;
    for (ts, 0..) |token, i| {
        if (!top(source, token.offset)) continue;
        if (token.is("__all__")) {
            names.clearRetainingCapacity();
            literal = false;
            if (i + 2 >= ts.len or !ts[i + 1].is("=") or (!ts[i + 2].is("[") and !ts[i + 2].is("("))) continue;
            const closing = if (ts[i + 2].is("[")) "]" else ")";
            var j = i + 3;
            var valid = true;
            var string_expected = true;
            while (j < ts.len and !ts[j].is(closing)) : (j += 1) {
                if (ts[j].kind == .newline) continue;
                if (string_expected and ts[j].kind == .string) {
                    try names.append(arena, try l.decode(arena, ts[j].text));
                    string_expected = false;
                } else if (!string_expected and ts[j].is(",")) string_expected = true else valid = false;
            }
            literal = valid and j < ts.len and (j + 1 == ts.len or ts[j + 1].kind == .newline);
        }
        if (!token.is("from")) continue;
        var base: ?Spec = null;
        for (specs) |spec| if (spec.offset == token.offset and spec.python_base) {
            base = spec;
            break;
        };
        if (base == null) continue;
        var j = i + 1;
        while (j < ts.len and !ts[j].is("import") and ts[j].kind != .newline) : (j += 1) {}
        j += 1;
        var parens: usize = 0;
        while (j < ts.len) : (j += 1) {
            const t = ts[j];
            if (t.is("(")) {
                parens += 1;
                continue;
            }
            if (t.is(")")) {
                if (parens > 0) parens -= 1;
                continue;
            }
            if (t.kind == .newline) {
                if (parens == 0) break;
                continue;
            }
            if (t.is(",") or t.is("\\")) continue;
            if (t.kind != .word) break;
            const child_name = t.text;
            var bound = child_name;
            if (j + 2 < ts.len and ts[j + 1].is("as")) {
                bound = ts[j + 2].text;
                j += 2;
            }
            for (specs) |spec| if (spec.offset == token.offset and !spec.python_base) {
                const last = std.mem.findScalarLast(u8, spec.name, '.') orelse 0;
                if (std.mem.eql(u8, spec.name[last + 1 ..], child_name)) try exports.append(arena, .{ .name = bound, .base = base.?, .child = spec });
            };
        }
    }
    if (!literal) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (exports.items) |exported| {
        var exposed = false;
        for (names.items) |name| if (std.mem.eql(u8, name, exported.name)) {
            exposed = true;
        };
        if (!exposed) continue;
        const child = try ctx.targets(from, .python, exported.child);
        const resolved = if (child.len > 0) child else try ctx.targets(from, .python, exported.base);
        if (resolved.len > 0) try out.append(arena, try arena.dupe(u8, resolved[0]));
    }
    return out.toOwnedSlice(arena);
}
pub fn index(arena: std.mem.Allocator, gpa: std.mem.Allocator, strings: std.mem.Allocator, paths: []const []const u8, ctx: anytype, context: anytype, comptime read: anytype, cached: []?types_module.Recovery, progress: *diagnostic_module.Progress, recorder: *tokens_module.Recorder) (diagnostic_module.ReadError(read) || error{ InvalidPath, OutOfMemory })!std.StringHashMapUnmanaged([]const []const u8) {
    progress.at(.python_exports, null);
    var out: std.StringHashMapUnmanaged([]const []const u8) = .empty;
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    for (paths, 0..) |file, file_index| {
        if (!std.mem.endsWith(u8, file, ".py")) continue;
        const s = scratch.allocator();
        defer _ = scratch.reset(.retain_capacity);
        const source = (try read(context, s, file)) orelse continue;
        progress.at(.python_exports, file);
        const tokens = try recorder.lex(python, s, file_index, file, .python, source);
        const recovery = python.recoverTokens(s, source, tokens) catch |err| {
            try progress.tolerate(err);
            if (cached.len > 0) cached[file_index] = .{};
            continue;
        };
        if (cached.len > 0) cached[file_index] = try recovery.clone(arena, strings);
        var resolver = ctx;
        resolver.allocator = s;
        resolver.python_initializers = .explicit;
        // An export list that does not decode exports nothing.
        const found = targets(s, source, file, resolver, tokens, recovery.specs) catch |err| empty: {
            try progress.tolerate(err);
            break :empty &.{};
        };
        if (found.len > 0) {
            const owned = try arena.alloc([]const u8, found.len);
            for (found, owned) |target, *dest| dest.* = try arena.dupe(u8, target);
            try out.put(arena, file, owned);
        }
    }
    return out;
}
