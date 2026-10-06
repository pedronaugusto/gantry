//! Which Zig imports only a test build sees. Zig analyses lazily: code in a
//! `test` declaration, in the taken branch of `if (builtin.is_test)`, or in a
//! container-level declaration that nothing but tests reaches is never
//! compiled outside `zig test`. Read in the passes recovery already makes:
//! `Shape.read` in its pass over every token, `Words.see` in its pass over
//! the words.
const std = @import("std");
const l = @import("../../lexer.zig");
const types = @import("../../types.zig");
const Token = l.Token;

/// Token indices, both ends included.
const Range = struct { first: u32, last: u32 };

/// What one pass over a file's tokens finds for recovery and liveness.
pub const Shape = struct {
    /// Each `@` that starts an `@import`.
    imports: []const u32,
    /// For each bracket its partner; an unclosed one runs to the last token
    /// and a stray closer is its own partner. Other tokens are left undefined.
    partner: []const u32,
    /// Disjoint and in order: `test` bodies at any depth, and the
    /// then-branches of `if (builtin.is_test)`, `if (comptime
    /// builtin.is_test)` and `if (@import("builtin").is_test)`, where
    /// `builtin` is any container-level `const` bound to `@import("builtin")`.
    tests: []const Range,

    pub fn read(a: std.mem.Allocator, ts: []const Token) !Shape {
        const partner = try a.alloc(u32, ts.len);
        var open: std.ArrayList(u32) = .empty;
        var imports: std.ArrayList(u32) = .empty;
        var marks: std.ArrayList(u32) = .empty;
        var builtins: std.ArrayList([]const u8) = .empty;
        for (ts, 0..) |t, i| switch (t.kind) {
            .punctuation => switch (t.text[0]) {
                '(', '[', '{' => try open.append(a, @intCast(i)),
                ')', ']', '}' => {
                    const o = open.pop() orelse @as(u32, @intCast(i));
                    partner[o] = @intCast(i);
                    partner[i] = o;
                },
                '@' => if (i + 1 < ts.len and ts[i + 1].is("import")) {
                    try imports.append(a, @intCast(i));
                    if (open.items.len == 0 and i >= 3 and ts[i - 3].is("const") and ts[i - 2].kind == .word and ts[i - 1].is("=") and builtinImport(ts, i))
                        try builtins.append(a, ts[i - 2].text);
                },
                else => {},
            },
            .word => if (t.text.len == 4 or t.text.len == 7) if (t.is("test") or t.is("is_test")) try marks.append(a, @intCast(i)),
            else => {},
        };
        for (open.items) |o| partner[o] = @intCast(ts.len - 1);
        // Marks are in order and each range starts at or after its mark, so
        // the ranges come in order of their first token.
        var tests: std.ArrayList(Range) = .empty;
        for (marks.items) |i| {
            const range: Range = if (testDecl(ts, i)) |brace| .{ .first = i, .last = partner[brace] } else if (isTestCondition(ts, i, builtins.items)) then: {
                const first = i + 2;
                if (first >= ts.len) continue;
                const last = if (ts[first].is("{")) partner[first] else expressionEnd(ts, partner, first) orelse continue;
                break :then .{ .first = first, .last = @intCast(last) };
            } else continue;
            if (tests.items.len > 0 and range.first <= tests.items[tests.items.len - 1].last) {
                const top = &tests.items[tests.items.len - 1];
                top.last = @max(top.last, range.last);
            } else try tests.append(a, range);
        }
        return .{ .imports = imports.items, .partner = partner, .tests = tests.items };
    }
};
fn opener(t: Token) bool {
    return t.kind == .punctuation and (t.text[0] == '(' or t.text[0] == '[' or t.text[0] == '{');
}
fn closer(t: Token) bool {
    return t.kind == .punctuation and (t.text[0] == ')' or t.text[0] == ']' or t.text[0] == '}');
}

/// The body brace of a `test` declaration starting at `i`: `test {`,
/// `test "name" {` or `test name {`.
fn testDecl(ts: []const Token, i: usize) ?usize {
    if (!ts[i].is("test") or i + 1 >= ts.len) return null;
    if (ts[i + 1].is("{")) return i + 1;
    if ((ts[i + 1].kind == .string or ts[i + 1].kind == .word) and i + 2 < ts.len and ts[i + 2].is("{")) return i + 2;
    return null;
}

/// `@import("builtin")` from the `@` at `i`.
fn builtinImport(ts: []const Token, i: usize) bool {
    return i + 4 < ts.len and ts[i + 2].is("(") and ts[i + 3].kind == .string and std.mem.eql(u8, ts[i + 3].text, "builtin") and ts[i + 4].is(")");
}
/// `is_test` at `i` closes `if (B.is_test)` or `if (comptime B.is_test)`,
/// where `B` is `@import("builtin")` or one of `builtins`, the names bound
/// to it. Another value's `is_test` is no evidence of a test build.
fn isTestCondition(ts: []const Token, i: usize, builtins: []const []const u8) bool {
    if (!ts[i].is("is_test") or i < 3 or i + 1 >= ts.len or !ts[i + 1].is(")") or !ts[i - 1].is(".")) return false;
    var k = i - 2;
    if (ts[k].kind == .word) {
        for (builtins) |name| {
            if (std.mem.eql(u8, name, ts[k].text)) break;
        } else return false;
        if (k == 0) return false;
        k -= 1;
    } else if (k >= 4 and ts[k].is(")") and builtinImport(ts, k - 4)) {
        if (k < 5) return false;
        k -= 5;
    } else return false;
    if (ts[k].is("comptime")) {
        if (k == 0) return false;
        k -= 1;
    }
    return k > 0 and ts[k].is("(") and ts[k - 1].is("if");
}
/// The last token of an expression starting at `first`: before the `else`,
/// `;`, `,` or closer that ends it at its own depth.
fn expressionEnd(ts: []const Token, partner: []const u32, first: usize) ?usize {
    var k = first;
    while (k < ts.len) {
        const t = ts[k];
        if (t.is("else") or t.is(";") or t.is(",") or closer(t)) break;
        k = if (opener(t)) partner[k] + 1 else k + 1;
    }
    return if (k > first) k - 1 else null;
}

const Member = struct { first: u32, last: u32, name: ?[]const u8 = null, root: bool = false, is_test: bool = false, this: bool = false };

/// The file's container-level members in order, tiling the stream.
fn rootMembers(a: std.mem.Allocator, ts: []const Token, partner: []const u32) ![]const Member {
    var out: std.ArrayList(Member) = .empty;
    var i: usize = 0;
    while (i < ts.len) {
        const m = memberFrom(ts, partner, i);
        try out.append(a, m);
        i = m.last + 1;
    }
    return out.items;
}
fn memberFrom(ts: []const Token, partner: []const u32, first: usize) Member {
    var m: Member = .{ .first = @intCast(first), .last = @intCast(first) };
    var k = first;
    while (k < ts.len) : (k += 1) {
        const t = ts[k];
        if (t.is("pub") or t.is("export")) {
            m.root = true;
        } else if (t.is("comptime")) {
            m.root = true;
            if (k + 1 < ts.len and ts[k + 1].is("{")) return ending(m, partner[k + 1]);
        } else if (t.is("extern")) {
            if (k + 1 < ts.len and ts[k + 1].kind == .string) k += 1;
        } else if (!(t.is("inline") or t.is("noinline") or t.is("threadlocal"))) break;
    }
    if (k >= ts.len) return ending(m, ts.len - 1);
    if (testDecl(ts, k)) |brace| {
        m.is_test = true;
        return ending(m, partner[brace]);
    }
    const t = ts[k];
    if (t.is("fn") or t.is("const") or t.is("var")) {
        if (k + 1 < ts.len and ts[k + 1].kind == .word) m.name = ts[k + 1].text;
        if (m.name) |name| if (std.mem.eql(u8, name, "main")) {
            m.root = true;
        };
        m.this = k + 6 < ts.len and ts[k + 2].is("=") and ts[k + 3].is("@") and ts[k + 4].is("This") and ts[k + 5].is("(") and ts[k + 6].is(")");
        return ending(m, declarationEnd(ts, partner, k, t.is("fn")));
    }
    // A field, `usingnamespace` or bytes that are no declaration.
    m.root = true;
    return ending(m, fieldEnd(ts, partner, k));
}
fn ending(m: Member, end: usize) Member {
    var out = m;
    out.last = @intCast(@max(end, m.first));
    return out;
}
/// The `;` that ends a declaration, or a function's body brace.
fn declarationEnd(ts: []const Token, partner: []const u32, start: usize, function: bool) usize {
    var k = start;
    while (k < ts.len) {
        const t = ts[k];
        if (t.is(";")) return k;
        if (closer(t)) return k -| 1;
        if (function and t.is("{") and body(ts, partner, k)) return partner[k];
        k = if (opener(t)) partner[k] + 1 else k + 1;
    }
    return ts.len - 1;
}
/// A brace after a signature opens the body unless it opens a type in the
/// return type: `error{`, `struct {`, `union(enum) {`.
fn body(ts: []const Token, partner: []const u32, k: usize) bool {
    if (k == 0) return true;
    const prev = ts[k - 1];
    if (prev.is(")")) {
        const o = partner[k - 1];
        return o == 0 or !container(ts[o - 1]);
    }
    return !prev.is("error") and !container(prev);
}
fn container(t: Token) bool {
    return t.is("struct") or t.is("union") or t.is("enum") or t.is("opaque");
}
fn fieldEnd(ts: []const Token, partner: []const u32, start: usize) usize {
    var k = start;
    while (k < ts.len) {
        const t = ts[k];
        if (t.is(";") or t.is(",")) return k;
        if (closer(t)) return k -| 1;
        k = if (opener(t)) partner[k] + 1 else k + 1;
    }
    return ts.len - 1;
}

const Reach = enum { dead, live, test_only };

/// The names of container-level members that are not roots, the only ones
/// a reference can change: by their lengths, then by a slot of length and
/// ends with the members that share it chained. Most words name no such
/// member, and most of those are passed over without reading their bytes.
const Names = struct {
    const none = std.math.maxInt(u32);
    members: []const Member,
    /// The names bound to `@This()`, roots or not.
    this: []const []const u8,
    /// Bit `n` for a name of `n` bytes, the last bit for any longer.
    lengths: u64 = 0,
    slots: *[1 << 12]u32,
    next: []u32,

    fn init(a: std.mem.Allocator, members: []const Member) !Names {
        const slots = try a.create([1 << 12]u32);
        @memset(slots, none);
        var this: std.ArrayList([]const u8) = .empty;
        var names: Names = .{ .members = members, .this = &.{}, .slots = slots, .next = try a.alloc(u32, members.len) };
        for (members, 0..) |m, i| if (m.name) |name| {
            if (m.this) try this.append(a, name);
            if (m.root) continue;
            names.lengths |= length(name);
            const slot = &slots[sketch(name)];
            names.next[i] = slot.*;
            slot.* = @intCast(i);
        };
        names.this = this.items;
        return names;
    }
    fn find(self: Names, word: []const u8) ?u32 {
        if (self.lengths & length(word) == 0) return null;
        var i = self.slots[sketch(word)];
        while (i != none) : (i = self.next[i]) if (std.mem.eql(u8, self.members[i].name.?, word)) return i;
        return null;
    }
    fn length(word: []const u8) u64 {
        return @as(u64, 1) << @intCast(@min(word.len, 63));
    }
    fn sketch(word: []const u8) u12 {
        return @truncate(word.len *% 1031 +% @as(usize, word[0]) *% 37 +% word[word.len - 1]);
    }
};

/// References between container-level members, gathered as recovery walks
/// a file's words and strings. Live from the roots (`pub`, `export`,
/// `comptime`, fields, `main`), else test-only from `test` declarations and
/// references in test context, else dead. References are names outside
/// field position, `x.name(` calls, `Self.name` where `Self` is `@This()`,
/// decl and enum literals (`.name` that follows no operand and initialises
/// no field) and `@field(Self, "name")`: Zig forbids a local that shadows a
/// container-level name, so a matching name is that declaration. A doubtful
/// case is a reference, so it errs towards live.
pub const Words = struct {
    const Ref = struct { from: u32, to: u32 };
    a: std.mem.Allocator,
    ts: []const Token,
    tests: []const Range,
    members: []const Member,
    names: Names,
    refs: std.ArrayList(Ref) = .empty,
    seeds: std.ArrayList(u32) = .empty,
    /// The member that last named each target: members come in order, so
    /// a repeat from the same member is dropped.
    named_by: []u32,
    seeded: []bool,
    /// The member and test range at or after the last word seen.
    at: usize = 0,
    in: usize = 0,

    pub fn init(a: std.mem.Allocator, ts: []const Token, shape: Shape) !Words {
        const members = try rootMembers(a, ts, shape.partner);
        const named_by = try a.alloc(u32, members.len);
        @memset(named_by, Names.none);
        const seeded = try a.alloc(bool, members.len);
        @memset(seeded, false);
        return .{ .a = a, .ts = ts, .tests = shape.tests, .members = members, .names = try .init(a, members), .named_by = named_by, .seeded = seeded };
    }
    /// Each word and string of the stream, in order.
    pub fn see(self: *Words, i: usize) !void {
        const target = self.names.find(self.ts[i].text) orelse return;
        if (!reference(self.ts, i, self.names)) return;
        while (self.members[self.at].last < i) self.at += 1;
        while (self.in < self.tests.len and self.tests[self.in].last < i) self.in += 1;
        if (self.in < self.tests.len and self.tests[self.in].first <= i) {
            if (!self.seeded[target]) try self.seeds.append(self.a, target);
            self.seeded[target] = true;
        } else if (self.at != target and self.named_by[target] != self.at) {
            self.named_by[target] = @intCast(self.at);
            try self.refs.append(self.a, .{ .from = @intCast(self.at), .to = target });
        }
    }
    /// After every word: marks `test` each spec whose token only a test
    /// build analyses, and `dead` each one no build analyses. A dead import
    /// keeps its kind, since dead code is no evidence of a test. `where`
    /// holds the index in the stream of each spec's token.
    pub fn classify(self: *Words, specs: []types.Spec, where: []const u32) !void {
        std.debug.assert(specs.len == where.len);
        const reach = try self.reachable();
        for (specs, where) |*spec, at| {
            const member = reach[memberAt(self.members, at)];
            spec.dead = member == .dead;
            if (spec.kind == .import and (rangeAt(self.tests, at) or member == .test_only)) spec.kind = .@"test";
        }
    }
    fn reachable(self: *Words) ![]const Reach {
        const a = self.a;
        const n = self.members.len;
        // Edges grouped by source for the walk.
        const starts = try a.alloc(u32, n + 1);
        @memset(starts, 0);
        for (self.refs.items) |r| starts[r.from + 1] += 1;
        for (1..starts.len) |i| starts[i] += starts[i - 1];
        const targets = try a.alloc(u32, self.refs.items.len);
        const fill = try a.dupe(u32, starts[0..n]);
        for (self.refs.items) |r| {
            targets[fill[r.from]] = r.to;
            fill[r.from] += 1;
        }
        const out = try a.alloc(Reach, n);
        @memset(out, .dead);
        var stack: std.ArrayList(u32) = .empty;
        for ([_]Reach{ .live, .test_only }) |mark| {
            for (self.members, 0..) |m, i| if (if (mark == .live) m.root else m.is_test) try stack.append(a, @intCast(i));
            if (mark == .test_only) try stack.appendSlice(a, self.seeds.items);
            while (stack.pop()) |i| {
                if (out[i] != .dead) continue;
                out[i] = mark;
                for (targets[starts[i]..starts[i + 1]]) |j| if (out[j] == .dead) try stack.append(a, j);
            }
        }
        return out;
    }
};
fn reference(ts: []const Token, i: usize, names: Names) bool {
    if (ts[i].kind == .string) return i >= 2 and ts[i - 1].is(",") and i + 1 < ts.len and ts[i + 1].is(")") and fieldOfThis(ts, i - 2, names);
    const next_colon = i + 1 < ts.len and ts[i + 1].is(":");
    if (i == 0) return !next_colon;
    const prev = ts[i - 1];
    // `.name` after an operand is a member of something else unless called,
    // or of `@This()`; `..name` is a range bound.
    if (prev.is(".") and !(i >= 2 and ts[i - 2].is("."))) {
        if (i + 1 < ts.len and ts[i + 1].is("(")) return true;
        if (i < 2) return true;
        if (operand(ts, i - 2)) return containerThis(ts, i - 2, names);
        // A decl or enum literal, unless it names a field it initialises:
        // `.{ .name = x }`.
        const field = (ts[i - 2].is("{") or ts[i - 2].is(",")) and i + 2 < ts.len and ts[i + 1].is("=") and !(ts[i + 2].is("=") or ts[i + 2].is(">"));
        return !field;
    }
    // The label of `break :name` or `continue :name`.
    if (prev.is(":") and i >= 2 and (ts[i - 2].is("break") or ts[i - 2].is("continue"))) return false;
    // A field, parameter or label name, but not a sentinel `[n:0]` or `[a..n :0]`.
    return !next_colon or prev.is("[") or prev.is(".");
}

/// Whether the expression ending at `k` is `@This()` or a name bound to it.
fn containerThis(ts: []const Token, k: usize, names: Names) bool {
    const owner = ts[k];
    if (owner.kind == .word) {
        for (names.this) |name| if (std.mem.eql(u8, name, owner.text)) return true;
        return false;
    }
    return owner.is(")") and k >= 3 and ts[k - 1].is("(") and ts[k - 2].is("This") and ts[k - 3].is("@");
}
/// `@field(T, ` before the `,` that follows `k`, with `T` the container.
fn fieldOfThis(ts: []const Token, k: usize, names: Names) bool {
    if (!containerThis(ts, k, names)) return false;
    const open = if (ts[k].kind == .word) k -| 1 else k -| 4;
    return open >= 2 and ts[open].is("(") and ts[open - 1].is("field") and ts[open - 2].is("@");
}
/// Whether token `k` ends an operand, so a `.name` after it is a member:
/// a name that is no keyword (`error` is one), a literal, a closer, or the
/// `?` and `*` of `x.?` and `x.*`. A label (`break :blk .x`) is none.
fn operand(ts: []const Token, k: usize) bool {
    const t = ts[k];
    return switch (t.kind) {
        .word => (std.zig.Token.getKeyword(t.text) == null or t.is("error")) and !(k >= 2 and ts[k - 1].is(":") and (ts[k - 2].is("break") or ts[k - 2].is("continue"))),
        .string, .template => true,
        .punctuation => closer(t) or ((t.is("?") or t.is("*")) and k >= 1 and ts[k - 1].is(".")),
        .newline => false,
    };
}

/// The member holding token `i`; members tile the stream.
fn memberAt(members: []const Member, i: usize) usize {
    var lo: usize = 0;
    var hi: usize = members.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (members[mid].last < i) lo = mid + 1 else hi = mid;
    }
    return lo;
}
fn rangeAt(ranges: []const Range, i: usize) bool {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (ranges[mid].last < i) lo = mid + 1 else hi = mid;
    }
    return lo < ranges.len and ranges[lo].first <= i;
}
