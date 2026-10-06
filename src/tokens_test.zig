const std = @import("std");
const g = @import("gantry.zig");
const f = @import("testing/support.zig");
const a = std.testing.allocator;
const eq = std.testing.expectEqual;
const eqs = std.testing.expectEqualStrings;

const rules: []const g.rules.TokenRule = &.{
    .{ .name = "owned name", .token = "Owned" },
    .{ .name = "owned value", .kind = .string, .token = "owned value" },
};

/// Each language spells `Owned` once as a name and `owned value` once as a
/// string, and both again in comments, character literals and other kinds.
const sources = [_]f.Item{
    .{ .path = "a.zig", .text = "// Owned \"owned value\"\n/// Owned\nconst x = Owned; const y = \"owned value\"; const z = 'O'; const w = \\\\Owned \"owned value\"\n;" },
    .{ .path = "a.c", .text = "/* Owned \"owned value\" */\n// Owned\nint x = Owned; const char *y = \"owned value\"; char z = 'O';" },
    .{ .path = "a.ts", .text = "// Owned 'owned value'\n/* Owned */\nconst x = Owned; const y = 'owned value'; const z = `owned value ${\"q\"}`; const r = /Owned/;" },
    .{ .path = "a.py", .text = "# Owned \"owned value\"\nx = Owned\ny = 'owned value'\n\"\"\"Owned owned value\"\"\"\n" },
    .{ .path = "a.go", .text = "package a\n// Owned \"owned value\"\n/* Owned */\nvar x = Owned\nvar y = \"owned value\"\nvar z = 'O'\n" },
    .{ .path = "a.rs", .text = "// Owned \"owned value\"\n/* Owned /* nested */ \"owned value\" */\nlet x = Owned; let y = \"owned value\"; let z = r#\"Owned\"#; let c = 'O';\n" },
    .{ .path = "a.nim", .text = "# Owned \"owned value\"\n#[ Owned ]#\nlet x = Owned\nlet y = \"owned value\"\nlet z = 'O'\n" },
    .{ .path = "A.java", .text = "// Owned \"owned value\"\n/** Owned */\nclass A { Object x = Owned; String y = \"owned value\"; char z = 'O'; String t = \"\"\"\nOwned\n\"\"\"; }\n" },
};

test "token rules match names and string values in every language, never comments or other kinds" {
    var graph = try (f.Fixture{ .items = &sources }).scan(a, .{ .tokens = rules });
    defer graph.deinit();
    const tokens = graph.tokens();
    try eq(2 * sources.len, tokens.len);
    for (sources) |source| {
        const i = for (tokens, 0..) |token, i| {
            if (std.mem.eql(u8, token.path, source.path)) break i;
        } else return error.TestExpectedToken;
        const name = tokens[i];
        const value = tokens[i + 1];
        try eqs(source.path, value.path);
        try eq(.identifier, name.kind);
        try eqs("Owned", name.text);
        try eq(.string, value.kind);
        try eqs("owned value", value.text);
        try eqs("Owned", source.text.?[name.offset..][0..5]);
    }
    var findings_owned = try graph.check(a, .{ .tokens = rules });
    defer findings_owned.deinit();
    const findings = findings_owned.items();
    try eq(2 * sources.len, findings.len);
    // Rule order, then path and offset.
    for (findings[0..sources.len]) |finding| try eqs("owned name", finding.rule);
    try eq(.token, findings[0].reason);
    try eqs("A.java", findings[0].token.?.path);
}

test "a token rule reports path line and column outside its owners" {
    const fixture: f.Fixture = .{ .items = &.{
        .{ .path = "src/owner/os.zig", .text = "pub fn open() void { CreateFileW(); }" },
        .{ .path = "src/owner/deep/tty.zig", .text = "const s = \"\\x1b[0m\";" },
        .{ .path = "src/app.zig", .text = "const a = 1;\n\n  const b = CreateFileW;\n// CreateFileW\nconst c = \"x\\x1b[?25h\";" },
        .{ .path = "src/tests/fixture.zig", .text = "const t = \"\\u{1b}[\";" },
    } };
    const owned: []const g.rules.TokenRule = &.{
        .{ .name = "console", .token = "CreateFileW", .owners = &.{"src/owner/*.zig"} },
        .{ .name = "sequences", .kind = .string, .token = "*\x1b[*", .owners = &.{ "src/owner/**", "fixture.zig" } },
    };
    var graph = try fixture.scan(a, .{ .tokens = owned });
    defer graph.deinit();
    try eq(5, graph.tokens().len);
    var findings_owned = try graph.check(a, .{ .tokens = owned });
    defer findings_owned.deinit();
    const findings = findings_owned.items();
    try eq(2, findings.len);
    try eqs("console", findings[0].rule);
    const name = findings[0].token.?;
    try eqs("src/app.zig", name.path);
    try eq(3, name.line);
    try eq(13, name.column);
    try eqs("CreateFileW", name.text);
    try eqs("sequences", findings[1].rule);
    const value = findings[1].token.?;
    try eq(5, value.line);
    try eq(11, value.column);
    try eqs("x\x1b[?25h", value.text);
}

test "string values are compared after each language's escapes" {
    const fixture: f.Fixture = .{ .items = &.{
        .{ .path = "a.zig", .text = "const a = \"\\x1b[\"; const b = \"\\u{1b}[\"; const c = @\"\\x1b[\";" },
        .{ .path = "a.c", .text = "char *a = \"\\033[\"; char *b = \"\\e[\"; char *c = \"\\x1b[\"; char *d = \"\\x1B\\x5b\";" },
        .{ .path = "a.go", .text = "package a\nvar a = \"\\x1b[\"\nvar b = \"\\033[\"\nvar c = \"\\u001b[\"\nvar raw = `\\x1b[`\nvar r = '\\x1b'\n" },
        .{ .path = "a.py", .text = "a = '\\x1b['\nb = \"\\033[\"\nc = '\\u001b['\nraw = r'\\x1b['\n" },
        .{ .path = "a.ts", .text = "const a = '\\x1b['; const b = \"\\u001b[\"; const c = '\\u{1b}[';" },
        .{ .path = "a.rs", .text = "let a = \"\\x1b[\"; let b = \"\\u{1b}[\"; let raw = r\"\\x1b[\";" },
        .{ .path = "a.nim", .text = "let a = \"\\e[\"\nlet b = \"\\27[\"\nlet c = \"\\x1b[\"\nlet raw = r\"\\x1b[\"\n" },
        .{ .path = "A.java", .text = "class A { String a = \"\\u001b[\"; String b = \"\\033[\"; String c = \"\\x1b[\"; }" },
    } };
    const owned: []const g.rules.TokenRule = &.{.{ .name = "csi", .kind = .string, .token = "\x1b[" }};
    var graph = try fixture.scan(a, .{ .tokens = owned });
    defer graph.deinit();
    var per_file: [8]usize = @splat(0);
    const order = [_][]const u8{ "A.java", "a.c", "a.go", "a.nim", "a.py", "a.rs", "a.ts", "a.zig" };
    for (graph.tokens()) |token| {
        for (order, 0..) |path, i| if (std.mem.eql(u8, path, token.path)) {
            per_file[i] += 1;
        };
        try eqs("\x1b[", token.text);
    }
    // Java has no `\x`; a Zig `@"…"` is a name; raw strings keep backslashes;
    // a Go rune is not a string.
    try eq([8]usize{ 2, 4, 3, 3, 3, 2, 3, 2 }, per_file);
}

test "numbers are not names and Zig quoted names are" {
    const fixture: f.Fixture = .{ .items = &.{
        .{ .path = "a.zig", .text = "const a = 27; const b = @\"kill\"; const c = .kill; const d = \"kill\";" },
    } };
    const owned: []const g.rules.TokenRule = &.{
        .{ .name = "number", .token = "27" },
        .{ .name = "kill", .token = "kill" },
    };
    var graph = try fixture.scan(a, .{ .tokens = owned });
    defer graph.deinit();
    try eq(2, graph.tokens().len);
    for (graph.tokens()) |token| try eqs("kill", token.text);
}

test "token rules read sources when no reference kind would" {
    const fixture: f.Fixture = .{ .items = &.{
        .{ .path = "a.zig", .text = "const x = waitpid;" },
        .{ .path = "a.go", .text = "package a\nvar x = waitpid\n" },
        .{ .path = "a.rs", .text = "let x = waitpid;" },
        .{ .path = "A.java", .text = "class A { int x = waitpid; }" },
        .{ .path = "a.py", .text = "x = waitpid" },
        .{ .path = "notes.md", .text = "waitpid" },
    } };
    const owned: []const g.rules.TokenRule = &.{.{ .name = "process", .token = "waitpid" }};
    for ([_]bool{ false, true }) |reexports| {
        var graph = try fixture.scan(a, .{ .kinds = &.{.link}, .manifests = false, .python_star_reexports = reexports, .tokens = owned });
        defer graph.deinit();
        try eq(5, graph.tokens().len);
    }
    var full = try fixture.scan(a, .{ .tokens = owned });
    defer full.deinit();
    try eq(5, full.tokens().len);
}

test "a token rule the scan did not record is refused" {
    var graph = try (f.Fixture{ .items = &.{.{ .path = "a.zig", .text = "const x = kill;" }} }).scan(a, .{});
    defer graph.deinit();
    try eq(0, graph.tokens().len);
    try std.testing.expectError(error.UnscannedToken, graph.check(a, .{ .tokens = &.{.{ .name = "kill", .token = "kill" }} }));
    try std.testing.expectError(error.UnscannedToken, g.rules.check(a, &graph, .{ .tokens = &.{.{ .name = "kill", .token = "kill" }} }));
}

test "token patterns: star spans any bytes and question mark one" {
    const cases = [_]struct { pattern: []const u8, text: []const u8, want: bool }{
        .{ .pattern = "kill", .text = "kill", .want = true },
        .{ .pattern = "kill", .text = "killpg", .want = false },
        .{ .pattern = "Create*W", .text = "CreateFileW", .want = true },
        .{ .pattern = "*.git*", .text = "a/.git/config", .want = true },
        .{ .pattern = "*.git", .text = ".gitignore", .want = false },
        .{ .pattern = "\x1b?", .text = "\x1b]", .want = true },
    };
    for (cases) |case| try eq(case.want, g.rules.matchesToken(case.pattern, case.text));
}

fn tokenAllocations(allocator: std.mem.Allocator) !void {
    var graph = try (f.Fixture{ .items = &sources }).scan(allocator, .{ .tokens = rules });
    defer graph.deinit();
    var findings_owned = try graph.check(allocator, .{ .tokens = rules });
    defer findings_owned.deinit();
}
test "token rule scans and checks release everything when allocation fails" {
    try std.testing.checkAllAllocationFailures(a, tokenAllocations, .{});
}
