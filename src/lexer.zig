//! Shared byte machinery, instantiated separately by each language module.
//! Tokens retain source offsets. Comments and character literals never emit words.
const std = @import("std");
const Language = @import("types.zig").Language;
pub const Token = struct {
    kind: enum { word, string, punctuation, newline },
    text: []const u8,
    offset: usize,
    end: usize,
    pub fn is(t: Token, s: []const u8) bool {
        return t.kind != .string and std.mem.eql(u8, t.text, s);
    }
};
pub fn lex(comptime lang: Language, a: std.mem.Allocator, text: []const u8) ![]const Token {
    var out: std.ArrayList(Token) = .empty;
    var i: usize = 0;
    var regex_allowed = true;
    var control_pending = false;
    var controls: std.ArrayList(bool) = .empty;
    var templates: std.ArrayList(usize) = .empty;
    while (i < text.len) {
        const start = i;
        const c = text[i];
        if ((lang == .python or lang == .c) and c == '\\' and i + 1 < text.len and text[i + 1] == '\n') {
            i += 2;
            continue;
        }
        if (lang == .javascript and (c == '`' or (c == '}' and templates.items.len > 0 and templates.items[templates.items.len - 1] == 0))) {
            if (c == '}') _ = templates.pop();
            i += 1;
            while (i < text.len) {
                if (text[i] == '\\') {
                    i = @min(i + 2, text.len);
                    continue;
                }
                if (text[i] == '`') {
                    i += 1;
                    break;
                }
                if (text[i] == '$' and i + 1 < text.len and text[i + 1] == '{') {
                    try templates.append(a, 0);
                    i += 2;
                    regex_allowed = true;
                    break;
                }
                i += 1;
            }
            continue;
        }
        if (c == '\n') {
            i += 1;
            try out.append(a, .{ .kind = .newline, .text = text[start..i], .offset = start, .end = i });
            continue;
        }
        if (std.ascii.isWhitespace(c)) {
            i += 1;
            continue;
        }
        if (lang == .python and c == '#') {
            i = lineEnd(text, i);
            continue;
        }
        if (lang != .python and i + 1 < text.len and c == '/' and text[i + 1] == '/') {
            i = lineEnd(text, i);
            continue;
        }
        if (lang != .python and lang != .zig and i + 1 < text.len and c == '/' and text[i + 1] == '*') {
            i += 2;
            var depth: usize = 1;
            while (i < text.len and depth > 0) {
                if (i + 1 < text.len and text[i] == '*' and text[i + 1] == '/') {
                    depth -= 1;
                    i += 2;
                } else if (lang == .rust and i + 1 < text.len and text[i] == '/' and text[i + 1] == '*') {
                    depth += 1;
                    i += 2;
                } else {
                    if (lang == .c and text[i] == '\n') try out.append(a, .{ .kind = .newline, .text = text[i .. i + 1], .offset = i, .end = i + 1 });
                    i += 1;
                }
            }
            continue;
        }
        if (lang == .zig and c == '\\' and i + 1 < text.len and text[i + 1] == '\\') {
            i = lineEnd(text, i);
            continue;
        }
        // Rust raw strings and C++ raw string literals.
        if (lang == .rust and c == 'r') {
            var q = i + 1;
            while (q < text.len and text[q] == '#') : (q += 1) {}
            if (q < text.len and text[q] == '"') {
                const hashes = q - i - 1;
                i = q + 1;
                while (i < text.len) : (i += 1) {
                    if (text[i] != '"' or i + 1 + hashes > text.len) continue;
                    var h: usize = 0;
                    while (h < hashes and text[i + 1 + h] == '#') : (h += 1) {}
                    if (h == hashes) {
                        i += 1 + hashes;
                        break;
                    }
                }
                continue;
            }
        }
        if (lang == .c and c == 'R' and i + 1 < text.len and text[i + 1] == '"') {
            const open = std.mem.indexOfScalarPos(u8, text, i + 2, '(') orelse text.len;
            if (open -| (i + 2) <= 16 and open < text.len) {
                const delimiter = text[i + 2 .. open];
                i = open + 1;
                while (i < text.len) : (i += 1) {
                    if (text[i] == ')' and std.mem.startsWith(u8, text[i + 1 ..], delimiter) and i + 1 + delimiter.len < text.len and text[i + 1 + delimiter.len] == '"') {
                        i += delimiter.len + 2;
                        break;
                    }
                }
                continue;
            }
        }
        if (lang == .javascript and c == '/' and regex_allowed) {
            i += 1;
            var bracket = false;
            while (i < text.len and text[i] != '\n') {
                if (text[i] == '\\') {
                    i = @min(i + 2, text.len);
                    continue;
                }
                if (text[i] == '[') bracket = true;
                if (text[i] == ']') bracket = false;
                if (text[i] == '/' and !bracket) {
                    i += 1;
                    break;
                }
                i += 1;
            }
            while (i < text.len and std.ascii.isAlphabetic(text[i])) : (i += 1) {}
            regex_allowed = false;
            continue;
        }
        if (c == '"' or c == '\'' or ((lang == .go or lang == .javascript) and c == '`')) {
            // A Rust lifetime is an identifier, not a character literal.
            if (lang == .rust and c == '\'' and i + 1 < text.len and ident(text[i + 1])) {
                var end = i + 2;
                while (end < text.len and ident(text[end])) : (end += 1) {}
                if (end == text.len or text[end] != '\'') {
                    i += 1;
                    continue;
                }
            }
            const triple = lang == .python and i + 2 < text.len and text[i + 1] == c and text[i + 2] == c;
            const width: usize = if (triple) 3 else 1;
            i += width;
            const content = i;
            while (i < text.len) {
                if (!(lang == .go and c == '`') and text[i] == '\\') {
                    i = @min(i + 2, text.len);
                    continue;
                }
                if (text[i] == c and (!triple or (i + 2 < text.len and text[i + 1] == c and text[i + 2] == c))) break;
                i += 1;
            }
            const end = i;
            const closed = i < text.len;
            i = @min(i + width, text.len);
            if (closed and !triple and !(lang == .javascript and c == '`') and !(lang == .zig and c == '\'') and !(lang == .c and c == '\'') and !(lang == .rust and c == '\''))
                try out.append(a, .{ .kind = .string, .text = text[content..end], .offset = start, .end = i });
            regex_allowed = false;
            continue;
        }
        if (ident(c)) {
            i += 1;
            while (i < text.len and ident(text[i])) : (i += 1) {}
            const word = text[start..i];
            try out.append(a, .{ .kind = .word, .text = word, .offset = start, .end = i });
            control_pending = std.mem.eql(u8, word, "if") or std.mem.eql(u8, word, "while") or std.mem.eql(u8, word, "for") or std.mem.eql(u8, word, "with") or std.mem.eql(u8, word, "switch") or std.mem.eql(u8, word, "catch");
            regex_allowed = std.mem.eql(u8, word, "return") or std.mem.eql(u8, word, "throw") or std.mem.eql(u8, word, "case") or std.mem.eql(u8, word, "else") or std.mem.eql(u8, word, "do") or std.mem.eql(u8, word, "yield") or std.mem.eql(u8, word, "await") or std.mem.eql(u8, word, "typeof") or std.mem.eql(u8, word, "void") or std.mem.eql(u8, word, "delete") or std.mem.eql(u8, word, "in") or std.mem.eql(u8, word, "instanceof");
            continue;
        }
        i += 1;
        try out.append(a, .{ .kind = .punctuation, .text = text[start..i], .offset = start, .end = i });
        regex_allowed = std.mem.indexOfScalar(u8, "=(:,;!&|?{}", c) != null;
        if (lang == .javascript) {
            if (c == '(') {
                try controls.append(a, control_pending);
                control_pending = false;
            }
            if (c == ')') regex_allowed = controls.pop() orelse false;
            if (templates.items.len > 0) {
                if (c == '{') templates.items[templates.items.len - 1] += 1;
                if (c == '}') templates.items[templates.items.len - 1] -= 1;
            }
        }
    }
    return out.toOwnedSlice(a);
}
fn ident(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$' or c >= 128;
}
fn lineEnd(t: []const u8, i: usize) usize {
    return std.mem.indexOfScalarPos(u8, t, i, '\n') orelse t.len;
}
/// Drop newlines for languages where a declaration freely spans lines.
pub fn compact(a: std.mem.Allocator, tokens: []const Token) ![]const Token {
    var out: std.ArrayList(Token) = .empty;
    for (tokens) |t| if (t.kind != .newline) {
        try out.append(a, t);
    };
    return out.toOwnedSlice(a);
}
/// Decode the ordinary escapes shared by JS, Go and manifest literals.
/// Unsupported escapes are an error rather than an invented path.
pub fn decode(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '\\') == null) return text;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '\\') {
            try out.append(a, text[i]);
            continue;
        }
        i += 1;
        if (i == text.len) return error.InvalidEscape;
        switch (text[i]) {
            '\\', '\'', '"', '/' => try out.append(a, text[i]),
            'n' => try out.append(a, '\n'),
            'r' => try out.append(a, '\r'),
            't' => try out.append(a, '\t'),
            '\n' => {},
            'x', 'u', 'U' => {
                const n: usize = if (text[i] == 'x') 2 else if (text[i] == 'u') 4 else 8;
                if (i + 1 + n > text.len) return error.InvalidEscape;
                const code = std.fmt.parseInt(u21, text[i + 1 .. i + 1 + n], 16) catch return error.InvalidEscape;
                if (n == 2) try out.append(a, @intCast(code)) else {
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(code, &buf) catch return error.InvalidEscape;
                    try out.appendSlice(a, buf[0..len]);
                }
                i += n;
            },
            else => return error.InvalidEscape,
        }
    }
    return out.toOwnedSlice(a);
}
