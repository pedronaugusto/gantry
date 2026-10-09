//! Which Zig imports only a test build sees, and which no build analyses.
//! Zig analyses lazily: code in a `test` declaration, in the taken branch of
//! `if (builtin.is_test)`, or in a container-level declaration that nothing
//! but tests reaches is never compiled outside `zig test`. The facts are
//! glint's: where an identifier or member resolves, and in which context.
//! This file owns only the architecture policy over them, a reach walk over
//! the file's container-level members.
//!
//! What glint leaves unknown is read towards production, never towards
//! test or dead: a call it cannot resolve may call any member of that name,
//! and so may a decl literal (`.name`) or a reflection (`@field(T, "name")`),
//! whose type it does not infer.
const std = @import("std");
const glint = @import("glint");
const types = @import("../../types.zig");
const Ast = std.zig.Ast;
const Allocator = std.mem.Allocator;
const Projection = glint.Projection;
const none = std.math.maxInt(u32);

/// Token indices, both ends included.
const Range = struct { first: u32, last: u32 };

/// A container-level declaration, by its tokens. Roots are live whatever
/// reaches them: `pub`, `export`, `main`, `comptime` blocks and fields.
const Member = struct { first: u32, last: u32, root: bool, is_test: bool };

const Reach = enum { dead, live, test_only };

/// One file of a project, with the projection of that project.
pub const Facts = struct {
    project: *const glint.Project,
    file: glint.Project.FileId,
    tree: *const Ast,
    declarations: []const glint.Declaration,
    projection: *const Projection,
};

/// What a file's specs are, from its projection.
/// Results are in `arena`; `scratch` holds what the reading needs meanwhile.
pub fn read(arena: Allocator, scratch: Allocator, facts: Facts) error{ InvalidSource, OutOfMemory }!types.Recovery {
    const tree = facts.tree;
    const projection = facts.projection;
    var reading: Reading = .{ .arena = scratch, .facts = facts };
    try reading.members();
    try reading.testRanges();
    try reading.uses();
    const reach = try reading.reach();
    var specs: std.ArrayList(types.Spec) = .empty;
    // Each import's member access straight on the call: `@import("x").m`.
    const direct = try scratch.alloc(u32, projection.imports.len);
    @memset(direct, none);
    for (projection.references) |ref| {
        if (tree.nodeTag(nodeOf(ref.node)) != .field_access) continue;
        const lhs = tree.nodeData(nodeOf(ref.node)).node_and_token[0];
        if (reading.importAt(lhs)) |i| direct[i] = ref.node.raw();
    }
    for (projection.imports, direct) |imp, access| {
        const token = tree.nodeMainToken(nodeOf(imp.node));
        const offset = tree.tokenStart(token);
        // AstGen rejects an import of anything but a string literal, so a file
        // glint reports as parsed has a spelling for each; if one is ever
        // missing the file is not read.
        const name = try arena.dupe(u8, imp.spelling orelse return error.InvalidSource);
        try specs.append(arena, reading.classified(reach, .{ .name = name, .offset = offset }, token, imp.context));
        if (access == none) continue;
        const member = tree.tokenSlice(tree.nodeData(@fromBackingInt(access)).node_and_token[1]);
        try specs.append(arena, reading.classified(reach, .{ .name = name, .member = try arena.dupe(u8, member), .offset = offset }, token, imp.context));
    }
    // A member of an import through the alias it is bound to, read where
    // that binding is in scope.
    for (projection.references) |ref| {
        const node = nodeOf(ref.node);
        if (tree.nodeTag(node) != .field_access) continue;
        const lhs = tree.nodeData(node).node_and_token[0];
        if (tree.nodeTag(lhs) != .identifier) continue;
        const i = reading.importBound(lhs) orelse continue;
        const name = try arena.dupe(u8, projection.imports[i].spelling orelse continue);
        const token = tree.nodeMainToken(lhs);
        const member = tree.tokenSlice(tree.nodeData(node).node_and_token[1]);
        try specs.append(arena, reading.classified(reach, .{ .name = name, .member = try arena.dupe(u8, member), .offset = tree.tokenStart(token) }, token, ref.context));
    }
    return .{ .specs = try specs.toOwnedSlice(arena) };
}

fn nodeOf(id: glint.Project.NodeId) Ast.Node.Index {
    return @fromBackingInt(id.raw());
}

const Reading = struct {
    arena: Allocator,
    facts: Facts,
    list: []const Member = &.{},
    /// A member's declaration node to the member.
    by_node: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// A member that is no root, by name.
    by_name: std.StringHashMapUnmanaged(u32) = .empty,
    tests: []const Range = &.{},
    /// Uses between members, and the members tests use.
    edges: std.ArrayList(struct { from: u32, to: u32 }) = .empty,
    seeds: std.ArrayList(u32) = .empty,
    seeded: []bool = &.{},
    /// The member that last used each target; members come in order.
    used_by: []u32 = &.{},

    fn members(self: *Reading) Allocator.Error!void {
        const tree = self.facts.tree;
        const roots = tree.rootDecls();
        const out = try self.arena.alloc(Member, roots.len);
        for (roots, out, 0..) |node, *member, index| {
            member.* = .{ .first = tree.firstToken(node), .last = tree.lastToken(node), .root = true, .is_test = false };
            var buffer: [1]Ast.Node.Index = undefined;
            var key = node;
            var name: ?Ast.TokenIndex = null;
            if (tree.nodeTag(node) == .test_decl) {
                member.root = false;
                member.is_test = true;
            } else if (tree.fullFnProto(&buffer, node)) |function| {
                if (tree.nodeTag(node) == .fn_decl) key = tree.nodeData(node).node_and_node[0];
                name = function.name_token;
                member.root = function.visib_token != null or exports(tree, function.extern_export_inline_token);
            } else if (tree.fullVarDecl(node)) |variable| {
                name = variable.ast.mut_token + 1;
                member.root = variable.visib_token != null or exports(tree, variable.extern_export_token);
            }
            const token = name orelse continue;
            try self.by_node.put(self.arena, @backingInt(key), @intCast(index)); // safe: a file's root declarations fit its u32 node count.
            const text = try self.identifier(token) orelse continue;
            if (std.mem.eql(u8, text, "main")) member.root = true;
            if (!member.root) try self.by_name.put(self.arena, text, @intCast(index)); // safe: as above.
        }
        self.list = out;
        self.seeded = try self.arena.alloc(bool, out.len);
        @memset(self.seeded, false);
        self.used_by = try self.arena.alloc(u32, out.len);
        @memset(self.used_by, none);
    }

    fn exports(tree: *const Ast, token: ?Ast.TokenIndex) bool {
        return if (token) |t| tree.tokenTag(t) == .keyword_export else false;
    }

    /// The name a token spells; `@"quoted"` names are decoded.
    fn identifier(self: *Reading, token: Ast.TokenIndex) Allocator.Error!?[]const u8 {
        const raw = self.facts.tree.tokenSlice(token);
        if (!std.mem.startsWith(u8, raw, "@\"")) return raw;
        return std.zig.string_literal.parseAlloc(self.arena, raw[1..]) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidLiteral => null,
        };
    }

    /// The then-branches of `if (builtin.is_test)` and `if (comptime
    /// builtin.is_test)`, where `builtin` is `@import("builtin")` or a
    /// binding of it. Another value's `is_test` is no evidence of a test build.
    fn testRanges(self: *Reading) Allocator.Error!void {
        const tree = self.facts.tree;
        var found: std.ArrayList(Range) = .empty;
        for (tree.nodes.items(.tag), 0..) |tag, index| {
            if (tag != .if_simple and tag != .@"if") continue;
            const node: Ast.Node.Index = @fromBackingInt(@intCast(index)); // safe: a node index of this tree.
            const branch = tree.fullIf(node).?;
            var condition = branch.ast.cond_expr;
            if (tree.nodeTag(condition) == .@"comptime") condition = tree.nodeData(condition).node;
            if (tree.nodeTag(condition) != .field_access) continue;
            const access = tree.nodeData(condition).node_and_token;
            if (!std.mem.eql(u8, tree.tokenSlice(access[1]), "is_test")) continue;
            const import = self.importOf(access[0]) orelse continue;
            if (!std.mem.eql(u8, self.facts.projection.imports[import].spelling orelse continue, "builtin")) continue;
            try found.append(self.arena, .{ .first = tree.firstToken(branch.ast.then_expr), .last = tree.lastToken(branch.ast.then_expr) });
        }
        // Nested branches are inside another; the walk is in node order,
        // which is not token order.
        std.mem.sort(Range, found.items, {}, struct {
            fn less(_: void, x: Range, y: Range) bool {
                return x.first < y.first;
            }
        }.less);
        var merged: std.ArrayList(Range) = .empty;
        for (found.items) |range| {
            if (merged.items.len > 0 and range.first <= merged.items[merged.items.len - 1].last) {
                const top = &merged.items[merged.items.len - 1];
                top.last = @max(top.last, range.last);
            } else try merged.append(self.arena, range);
        }
        self.tests = merged.items;
    }

    /// The index in `imports` of the import call at `node`.
    fn importAt(self: *const Reading, node: Ast.Node.Index) ?usize {
        const imports = self.facts.projection.imports;
        var lo: usize = 0;
        var hi: usize = imports.len;
        const want = @backingInt(node);
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (imports[mid].node.raw() < want) lo = mid + 1 else hi = mid;
        }
        return if (lo < imports.len and imports[lo].node.raw() == want) lo else null;
    }

    /// The import `node` is, or the import of the binding `node` names.
    fn importOf(self: *const Reading, node: Ast.Node.Index) ?usize {
        return self.importAt(node) orelse if (self.facts.tree.nodeTag(node) == .identifier) self.importBound(node) else null;
    }

    /// The import that the identifier at `node` names through a binding
    /// `const alias = @import("x");`, in whatever scope it is declared.
    fn importBound(self: *const Reading, node: Ast.Node.Index) ?usize {
        const refs = self.facts.projection.references;
        var lo: usize = 0;
        var hi: usize = refs.len;
        const want = @backingInt(node);
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (refs[mid].node.raw() < want) lo = mid + 1 else hi = mid;
        }
        if (lo == refs.len or refs[lo].node.raw() != want) return null;
        const decl = refs[lo].definition orelse return null;
        const record = self.facts.declarations[decl.index];
        if (record.kind != .variable) return null;
        const init = (self.facts.tree.fullVarDecl(record.node) orelse return null).ast.init_node.unwrap() orelse return null;
        return self.importAt(init);
    }

    fn memberAt(self: *const Reading, token: u32) ?u32 {
        const list = self.list;
        var lo: usize = 0;
        var hi: usize = list.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (list[mid].last < token) lo = mid + 1 else hi = mid;
        }
        return if (lo < list.len and list[lo].first <= token) @intCast(lo) else null; // safe: bounded by the member count.
    }

    fn inTest(self: *const Reading, token: u32) bool {
        const ranges = self.tests;
        var lo: usize = 0;
        var hi: usize = ranges.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (ranges[mid].last < token) lo = mid + 1 else hi = mid;
        }
        return lo < ranges.len and ranges[lo].first <= token;
    }

    /// Records that the member holding `token` uses `target`.
    fn use(self: *Reading, token: u32, in_test: bool, target: u32) Allocator.Error!void {
        if (self.list[target].root) return;
        const from = self.memberAt(token) orelse return;
        if (in_test or self.inTest(token)) {
            if (!self.seeded[target]) try self.seeds.append(self.arena, target);
            self.seeded[target] = true;
        } else if (from != target and self.used_by[target] != from) {
            self.used_by[target] = from;
            try self.edges.append(self.arena, .{ .from = from, .to = target });
        }
    }

    fn uses(self: *Reading) Allocator.Error!void {
        const tree = self.facts.tree;
        for (self.facts.projection.references) |ref| {
            const decl = ref.definition orelse continue;
            const record = self.facts.declarations[decl.index];
            if (record.kind != .variable and record.kind != .function) continue;
            const target = self.by_node.get(@backingInt(record.node)) orelse continue;
            try self.use(tree.nodeMainToken(nodeOf(ref.node)), ref.context == .@"test", target);
        }
        // A call glint cannot resolve may be any member of its name.
        for (self.facts.projection.calls) |call| {
            if (call.unknown == null) continue;
            var buffer: [1]Ast.Node.Index = undefined;
            const callee = tree.fullCall(&buffer, nodeOf(call.node)).?.ast.fn_expr;
            if (tree.nodeTag(callee) != .field_access) continue;
            try self.named(tree.nodeData(callee).node_and_token[1], tree.nodeMainToken(nodeOf(call.node)), call.context == .@"test");
        }
        for (tree.nodes.items(.tag), 0..) |tag, index| {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(index)); // safe: a node index of this tree.
            switch (tag) {
                // A decl literal: `.name` takes the declaration of its result type.
                .enum_literal => try self.named(tree.nodeMainToken(node), tree.nodeMainToken(node), try self.contextAt(node)),
                // `test name {}` tests the declaration `name`.
                .test_decl => if (tree.nodeData(node).opt_token_and_node[0].unwrap()) |token| {
                    if (tree.tokenTag(token) == .identifier) try self.named(token, token, true);
                },
                .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
                    const builtin = tree.tokenSlice(tree.nodeMainToken(node));
                    if (!std.mem.eql(u8, builtin, "@field") and !std.mem.eql(u8, builtin, "@hasDecl")) continue;
                    var buffer: [2]Ast.Node.Index = undefined;
                    const args = builtinArgs(tree, node, &buffer);
                    if (args.len != 2 or tree.nodeTag(args[1]) != .string_literal) continue;
                    const token = tree.nodeMainToken(args[1]);
                    const text = std.zig.string_literal.parseAlloc(self.arena, tree.tokenSlice(token)) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.InvalidLiteral => continue,
                    };
                    if (self.by_name.get(text)) |target| try self.use(token, try self.contextAt(node), target);
                },
                else => {},
            }
        }
    }

    /// A use of the member named by `name_token`, made at `at`.
    fn named(self: *Reading, name_token: Ast.TokenIndex, at: Ast.TokenIndex, in_test: bool) Allocator.Error!void {
        const text = try self.identifier(name_token) orelse return;
        if (self.by_name.get(text)) |target| try self.use(at, in_test, target);
    }

    /// The context of a node glint did not project.
    fn contextAt(self: *const Reading, node: Ast.Node.Index) Allocator.Error!bool {
        const ctx = Projection.context(self.facts.project, self.facts.file, self.facts.tree.nodeMainToken(node)) catch return false;
        return ctx == .@"test";
    }

    /// Live from the roots, else test-only from tests and what they use, else dead.
    fn reach(self: *Reading) Allocator.Error![]const Reach {
        const n = self.list.len;
        // Edges grouped by source for the walk.
        const starts = try self.arena.alloc(u32, n + 1);
        @memset(starts, 0);
        for (self.edges.items) |e| starts[e.from + 1] += 1;
        for (1..starts.len) |i| starts[i] += starts[i - 1];
        const targets = try self.arena.alloc(u32, self.edges.items.len);
        const fill = try self.arena.dupe(u32, starts[0..n]);
        for (self.edges.items) |e| {
            targets[fill[e.from]] = e.to;
            fill[e.from] += 1;
        }
        const out = try self.arena.alloc(Reach, n);
        @memset(out, .dead);
        var stack: std.ArrayList(u32) = .empty;
        for ([_]Reach{ .live, .test_only }) |mark| {
            for (self.list, 0..) |m, i| if (if (mark == .live) m.root else m.is_test) try stack.append(self.arena, @intCast(i)); // safe: bounded by the member count.
            if (mark == .test_only) try stack.appendSlice(self.arena, self.seeds.items);
            while (stack.pop()) |i| {
                if (out[i] != .dead) continue;
                out[i] = mark;
                for (targets[starts[i]..starts[i + 1]]) |j| if (out[j] == .dead) try stack.append(self.arena, j);
            }
        }
        return out;
    }

    /// `spec` read at `token`: a test when a test context holds it or only a
    /// test build reaches its member, dead when no build analyses its member.
    /// A dead import keeps its kind, since dead code is no evidence of a test.
    fn classified(self: *const Reading, reach_of: []const Reach, spec: types.Spec, token: u32, context: Projection.Context) types.Spec {
        var out = spec;
        const member = reach_of[self.memberAt(token) orelse return out];
        out.dead = member == .dead;
        if (context == .@"test" or self.inTest(token) or member == .test_only) out.kind = .@"test";
        return out;
    }
};

fn builtinArgs(tree: *const Ast, node: Ast.Node.Index, buffer: *[2]Ast.Node.Index) []const Ast.Node.Index {
    return switch (tree.nodeTag(node)) {
        .builtin_call_two, .builtin_call_two_comma => blk: {
            var count: usize = 0;
            inline for (tree.nodeData(node).opt_node_and_opt_node) |item| if (item.unwrap()) |arg| {
                buffer[count] = arg;
                count += 1;
            };
            break :blk buffer[0..count];
        },
        .builtin_call, .builtin_call_comma => tree.extraDataSlice(tree.nodeData(node).extra_range, Ast.Node.Index),
        else => &.{},
    };
}
