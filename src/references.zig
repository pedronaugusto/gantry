//! CommonMark's reference links (0.31.2, §4.7 and §6.3): the link reference
//! definitions a document holds, read before its links, and the destination
//! a full (`[text][label]`), collapsed (`[label][]`) or shortcut (`[label]`)
//! reference names. A label matches as CommonMark matches it: Unicode case
//! folded (xenoglyph's full folding), its whitespace trimmed and each run of
//! it one space; the first definition of a label is the one. A definition
//! stands where a paragraph could begin: not inside a fence, not indented
//! four spaces, not in a paragraph's continuation. Definitions inside block
//! quotes and list items are not read. A label is at most 999 bytes, as
//! CommonMark's, and link text past that is not read as a reference, so
//! every search for a closer is bounded.
const std = @import("std");
const xenoglyph = @import("xenoglyph");

pub const max_label = 999;

pub const Definitions = struct {
    /// Each normalized label's destination as written, escapes kept.
    targets: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Where each definition lies, in order: no link is read inside one.
    spans: std.ArrayList(Span) = .empty,

    pub const Span = struct { start: usize, end: usize };

    /// The destination `label` names, or null when no definition has it.
    pub fn get(d: *const Definitions, arena: std.mem.Allocator, label: []const u8) std.mem.Allocator.Error!?[]const u8 {
        if (d.targets.count() == 0) return null;
        const key = try normalize(arena, label) orelse return null;
        return d.targets.get(key);
    }
};

/// Every link reference definition of `text`.
pub fn read(arena: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error!Definitions {
    var d: Definitions = .{};
    var i: usize = 0;
    var paragraph = false;
    var fence: Fence = .{};
    while (i < text.len) {
        const line_end = std.mem.findScalarPos(u8, text, i, '\n') orelse text.len;
        const next = if (line_end < text.len) line_end + 1 else text.len;
        const line = text[i..line_end];
        var indent: usize = 0;
        while (indent < line.len and line[indent] == ' ') : (indent += 1) {}
        const rest = line[indent..];
        if (fence.char != 0) {
            if (indent < 4 and fence.closedBy(rest)) fence = .{};
        } else if (blank(rest)) {
            paragraph = false;
        } else if (indent >= 4 or rest[0] == '\t') {
            // Indented code, or a paragraph's continuation: no definition.
        } else if (Fence.opens(rest)) |opened| {
            fence = opened;
            paragraph = false;
        } else if (!paragraph and rest[0] == '[') {
            if (try definition(arena, text, i + indent)) |def| {
                const entry = try d.targets.getOrPut(arena, def.label);
                if (!entry.found_existing) entry.value_ptr.* = def.destination;
                try d.spans.append(arena, .{ .start = i, .end = def.end });
                i = def.end;
                continue;
            }
            paragraph = true;
        } else {
            // An ATX heading is a line of its own; anything else is text.
            paragraph = rest[0] != '#';
        }
        i = next;
    }
    return d;
}

const Fence = struct {
    char: u8 = 0,
    len: usize = 0,

    fn opens(rest: []const u8) ?Fence {
        if (rest[0] != '`' and rest[0] != '~') return null;
        var n: usize = 0;
        while (n < rest.len and rest[n] == rest[0]) : (n += 1) {}
        return if (n >= 3) .{ .char = rest[0], .len = n } else null;
    }

    fn closedBy(f: Fence, rest: []const u8) bool {
        var n: usize = 0;
        while (n < rest.len and rest[n] == f.char) : (n += 1) {}
        return n >= f.len and blank(rest[n..]);
    }
};

fn blank(s: []const u8) bool {
    for (s) |c| if (c != ' ' and c != '\t' and c != '\r') return false;
    return true;
}

const Definition = struct { label: []const u8, destination: []const u8, end: usize };

/// The definition starting at `s` (its `[`), or null when none does: a
/// label, `:`, a destination after spaces and at most one line ending, an
/// optional title, and nothing else on its last line.
fn definition(arena: std.mem.Allocator, text: []const u8, s: usize) std.mem.Allocator.Error!?Definition {
    const close = labelEnd(text, s) orelse return null;
    if (close + 1 >= text.len or text[close + 1] != ':') return null;
    const label = try normalize(arena, text[s + 1 .. close]) orelse return null;
    const at = skipToContent(text, close + 2) orelse return null;
    const dest = destination(text, at) orelse return null;
    var t = dest.end;
    while (t < text.len and (text[t] == ' ' or text[t] == '\t')) : (t += 1) {}
    if (t >= text.len or text[t] == '\n' or text[t] == '\r') {
        // The line ends: a title may stand on the next, or the definition ends here.
        const line_after = lineAfter(text, t);
        const end = title(text, line_after) orelse line_after;
        return .{ .label = label, .destination = dest.text, .end = end };
    }
    // More on the destination's line: whitespace, then a title closing it.
    if (t == dest.end) return null;
    const end = title(text, t) orelse return null;
    return .{ .label = label, .destination = dest.text, .end = end };
}

/// The `]` closing the label opened at `s`, within `max_label` bytes, with
/// no unescaped `[` and no blank line inside.
pub fn labelEnd(text: []const u8, s: usize) ?usize {
    var j = s + 1;
    while (j < text.len and j - (s + 1) <= max_label) : (j += 1) {
        switch (text[j]) {
            '\\' => j += 1,
            '[' => return null,
            ']' => return if (normalizedEmpty(text[s + 1 .. j])) null else j,
            '\n' => if (blankLineAt(text, j + 1)) return null,
            else => {},
        }
    }
    return null;
}

/// The `]` closing link text opened at `s`, brackets balanced, within
/// `max_label` bytes.
pub fn textEnd(text: []const u8, s: usize) ?usize {
    var depth: usize = 0;
    var j = s + 1;
    while (j < text.len and j - (s + 1) <= max_label) : (j += 1) {
        switch (text[j]) {
            '\\' => j += 1,
            '[' => depth += 1,
            ']' => {
                if (depth == 0) return j;
                depth -= 1;
            },
            '\n' => if (blankLineAt(text, j + 1)) return null,
            else => {},
        }
    }
    return null;
}

fn normalizedEmpty(label: []const u8) bool {
    for (label) |c| if (!std.ascii.isWhitespace(c)) return false;
    return true;
}

/// Whether the line starting at `j` holds only whitespace.
fn blankLineAt(text: []const u8, j: usize) bool {
    var k = j;
    while (k < text.len and text[k] != '\n') : (k += 1) if (text[k] != ' ' and text[k] != '\t' and text[k] != '\r') return false;
    return true;
}

/// Past spaces and tabs and at most one line ending, to the destination;
/// null when a blank line or the end comes first.
fn skipToContent(text: []const u8, from: usize) ?usize {
    var j = from;
    var endings: u8 = 0;
    while (j < text.len) : (j += 1) {
        switch (text[j]) {
            ' ', '\t', '\r' => {},
            '\n' => {
                endings += 1;
                if (endings > 1) return null;
            },
            else => return j,
        }
    }
    return null;
}

const Destination = struct { text: []const u8, end: usize };

/// `<...>` on one line, or a run with no space or control byte and its
/// parentheses balanced; empty only in angle brackets.
fn destination(text: []const u8, at: usize) ?Destination {
    if (text[at] == '<') {
        var k = at + 1;
        while (k < text.len) : (k += 1) {
            switch (text[k]) {
                '\\' => k += 1,
                '\n', '<' => return null,
                '>' => return .{ .text = text[at + 1 .. k], .end = k + 1 },
                else => {},
            }
        }
        return null;
    }
    var k = at;
    var depth: usize = 0;
    while (k < text.len) : (k += 1) {
        const c = text[k];
        if (c <= ' ' or c == 0x7f) break;
        if (c == '\\') {
            k += 1;
            continue;
        }
        if (c == '(') {
            depth += 1;
            if (depth > 32) return null;
        }
        if (c == ')') {
            if (depth == 0) break;
            depth -= 1;
        }
    }
    if (k == at or depth != 0) return null;
    return .{ .text = text[at..@min(k, text.len)], .end = @min(k, text.len) };
}

/// Where the line holding `j` ends, past its line ending.
fn lineAfter(text: []const u8, j: usize) usize {
    const e = std.mem.findScalarPos(u8, text, j, '\n') orelse return text.len;
    return e + 1;
}

/// The end of a title starting at `from` (spaces before it allowed) and
/// what follows it on its line, past the line ending; null when there is
/// none, it holds a blank line, or more follows it on its last line.
fn title(text: []const u8, from: usize) ?usize {
    var j = from;
    while (j < text.len and (text[j] == ' ' or text[j] == '\t')) : (j += 1) {}
    if (j >= text.len) return null;
    const closer: u8 = switch (text[j]) {
        '"' => '"',
        '\'' => '\'',
        '(' => ')',
        else => return null,
    };
    var k = j + 1;
    while (k < text.len) : (k += 1) {
        const c = text[k];
        if (c == '\\') {
            k += 1;
            continue;
        }
        if (c == '\n' and blankLineAt(text, k + 1)) return null;
        if (closer == ')' and c == '(') return null;
        if (c == closer) break;
    } else return null;
    var e = k + 1;
    while (e < text.len and (text[e] == ' ' or text[e] == '\t' or text[e] == '\r')) : (e += 1) {}
    if (e < text.len and text[e] != '\n') return null;
    return if (e < text.len) e + 1 else e;
}

/// `label` as labels match: whitespace runs one space, trimmed, then fully
/// case folded; null when nothing is left.
pub fn normalize(arena: std.mem.Allocator, label: []const u8) std.mem.Allocator.Error!?[]const u8 {
    var collapsed: std.ArrayList(u8) = .empty;
    var space = false;
    for (label) |c| {
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            space = collapsed.items.len > 0;
            continue;
        }
        if (space) try collapsed.append(arena, ' ');
        space = false;
        try collapsed.append(arena, c);
    }
    if (collapsed.items.len == 0) return null;
    var folded: std.Io.Writer.Allocating = .init(arena);
    xenoglyph.case.write(.fold, collapsed.items, &folded.writer, .{}) catch return error.OutOfMemory;
    return folded.written();
}
