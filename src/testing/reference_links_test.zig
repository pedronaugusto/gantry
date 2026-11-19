//! CommonMark 0.31.2's reference links (§4.7 link reference definitions,
//! §6.3 reference links), each case the rule of the spec example it names,
//! written over this project's own file names.
const std = @import("std");
const recover = @import("../recover.zig");

/// The destinations `links` recovers from `text`, in order.
fn expectLinks(text: []const u8, want: []const []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const specs = try recover.links(arena_state.allocator(), text);
    errdefer for (specs) |s| std.debug.print("got {s}\n", .{s.name});
    try std.testing.expectEqual(want.len, specs.len);
    for (want, specs) |w, s| try std.testing.expectEqualStrings(w, s.name);
}

test "a definition and a shortcut reference to it (example 192), a title in either quote or parentheses" {
    try expectLinks("[guide]: guide.md \"The guide\"\n\n[guide]\n", &.{"guide.md"});
    try expectLinks("[guide]: guide.md 'The guide'\n\n[guide]\n", &.{"guide.md"});
    try expectLinks("[guide]: guide.md (The guide)\n\n[guide]\n", &.{"guide.md"});
}

test "indented up to three spaces, the destination and the title each on a line of their own (example 193)" {
    try expectLinks("   [guide]: \n      guide.md  \n           'the title'  \n\n[guide]\n", &.{"guide.md"});
}

test "a label with escaped brackets, a destination with balanced parentheses (example 194)" {
    try expectLinks("[Guide*one\\]]:notes/a(b).md 'title (with parens)'\n\n[Guide*one\\]]\n", &.{"notes/a(b).md"});
}

test "an angle-bracket destination holds spaces (example 195)" {
    try expectLinks("[Guide one]:\n<my notes.md>\n'title'\n\n[Guide one]\n", &.{"my notes.md"});
}

test "a title over several lines (example 196), but not across a blank line (example 197)" {
    try expectLinks("[guide]: guide.md '\ntitle\nline1\n'\n\n[guide]\n", &.{"guide.md"});
    try expectLinks("[guide]: guide.md 'title\n\nwith blank line'\n\n[guide]\n", &.{});
}

test "the destination on the next line (example 198); none at all is no definition (example 199)" {
    try expectLinks("[guide]:\nguide.md\n\n[guide]\n", &.{"guide.md"});
    try expectLinks("[guide]:\n\n[guide]\n", &.{});
}

test "an empty angle destination names no file (example 200); text after it with no space is no definition (example 201)" {
    try expectLinks("[guide]: <>\n\n[guide]\n", &.{});
    try expectLinks("[guide]: <guide.md>(more)\n\n[guide]\n", &.{});
}

test "a reference before its definition (example 203); the first of two definitions wins (example 204)" {
    try expectLinks("[guide]\n\n[guide]: guide.md\n", &.{"guide.md"});
    try expectLinks("[guide]\n\n[guide]: first.md\n[guide]: second.md\n", &.{"first.md"});
}

test "labels match without case (example 205), Unicode's included (example 206)" {
    try expectLinks("[GUIDE]: guide.md\n\n[Guide]\n", &.{"guide.md"});
    try expectLinks("[ΑΓΩ]: φου.md\n\n[αγω]\n", &.{"φου.md"});
}

test "a definition alone links nothing (example 207); a label over lines (example 208)" {
    try expectLinks("[guide]: guide.md\n", &.{});
    try expectLinks("[\nguide\n]: guide.md\nbar\n\n[guide]\n", &.{"guide.md"});
}

test "text after the title is no definition (example 209); a bad title on the next line leaves the definition (example 210)" {
    try expectLinks("[guide]: guide.md \"title\" ok\n\n[guide]\n", &.{});
    try expectLinks("[guide]: guide.md\n\"title\" ok\n\n[guide]\n", &.{"guide.md"});
}

test "indented four spaces is code (example 211); inside a fence is code (example 212)" {
    try expectLinks("    [guide]: guide.md \"title\"\n\n[guide]\n", &.{});
    try expectLinks("```\n[guide]: guide.md\n```\n\n[guide]\n", &.{});
}

test "a definition cannot interrupt a paragraph (example 213), but follows a heading (example 214) or a blank line" {
    try expectLinks("Text\n[guide]: guide.md\n\n[guide]\n", &.{});
    try expectLinks("# Heading\n[guide]: guide.md\n\n[guide]\n", &.{"guide.md"});
    try expectLinks("Text\n\n[guide]: guide.md\n\n[guide]\n", &.{"guide.md"});
}

test "several definitions in a row, a title on the line after its destination (example 217)" {
    try expectLinks("[a]: a.md \"a\"\n[b]: b.md\n  \"b\"\n[c]: c.md\n\n[a],\n[b],\n[c]\n", &.{ "a.md", "b.md", "c.md" });
}

test "full references (example 527), case-insensitive (example 539), by full case folding (example 540)" {
    try expectLinks("[the guide][g]\n\n[g]: guide.md\n", &.{"guide.md"});
    try expectLinks("[the guide][GuIdE]\n\n[guide]: guide.md\n", &.{"guide.md"});
    try expectLinks("[\u{1e9e}]\n\n[SS]: strasse.md\n", &.{"strasse.md"});
}

test "collapsed references (examples 553, 555) and shortcut references (example 557)" {
    try expectLinks("[guide][]\n\n[guide]: guide.md\n", &.{"guide.md"});
    try expectLinks("[Guide][]\n\n[guide]: guide.md\n", &.{"guide.md"});
    try expectLinks("[guide]\n\n[guide]: guide.md\n", &.{"guide.md"});
}

test "whitespace in a label folds to one space (example 541); an undefined label links nothing (example 543)" {
    try expectLinks("[Guide\n  one]: guide.md\n\n[the guide][Guide one]\n", &.{"guide.md"});
    try expectLinks("[nothing]\n[guide]\n\n[guide]: guide.md\n", &.{"guide.md"});
}

test "link text with nested brackets (example 528); an image by reference (example 582)" {
    try expectLinks("[the [inner [guide]]][g]\n\n[g]: guide.md\n", &.{"guide.md"});
    try expectLinks("![diagram][d]\n\n[d]: img/diagram.svg\n", &.{"img/diagram.svg"});
}

test "an escaped bracket is no reference (example 563), nor one in a code span; a URL or a fragment-only destination names no file" {
    try expectLinks("`[guide]` \\[guide]\n\n[guide]: guide.md\n", &.{});
    try expectLinks("[site] [anchor]\n\n[site]: https://example.org/a.md\n[anchor]: #part\n", &.{});
    try expectLinks("[guide]\n\n[guide]: guide.md#part\n", &.{"guide.md"});
}

test "inline links beside references are read as before" {
    try expectLinks("[one](one.md) and [two][t]\n\n[t]: two.md\n", &.{ "one.md", "two.md" });
}
