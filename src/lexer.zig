//! Shared byte machinery, instantiated separately by each language module.
//! Tokens retain source offsets. Comments and character literals never emit words.
const std = @import("std");
/// The rules a text is read with: each source language by its own name.
/// Manifests borrow the nearest rules (TOML reads as Python, go.mod as Go),
/// and Gradle build scripts are Groovy or Kotlin.
pub const Syntax = enum { zig, c, javascript, python, go, rust, nim, java, groovy, kotlin };
pub const Token = struct {
    /// A template is an opaque string: a JS template boundary, or a whole
    /// string literal whose text is not a plain value (a Nim raw string with a
    /// prefix, which can be a formatting call, or a Groovy or Kotlin string
    /// that interpolates `$name` or `${code}`).
    kind: enum { word, string, template, punctuation, newline },
    text: []const u8,
    offset: usize,
    end: usize,
    pub fn is(t: Token, s: []const u8) bool {
        return (t.kind == .word or t.kind == .punctuation) and std.mem.eql(u8, t.text, s);
    }
};
pub fn lex(comptime lang: Syntax, a: std.mem.Allocator, text: []const u8) ![]Token {
    return lexSeen(lang, a, text, null);
}
/// Called as each word or string joins a stream, with the stream so far.
pub const Observer = struct {
    context: *anyopaque,
    token: *const fn (context: *anyopaque, stream: []const Token) error{OutOfMemory}!void,
};
/// `lex`, telling `seen` of each word and string as it is emitted. One
/// lexer serves both, so a scan without observers runs the same code.
pub fn lexSeen(comptime lang: Syntax, a: std.mem.Allocator, text: []const u8, seen: ?Observer) ![]Token {
    return tokenize(lang, true, a, text, seen);
}
/// `compact(lexSeen(…))`, without emitting the newlines it would drop.
pub fn lexCompact(comptime lang: Syntax, a: std.mem.Allocator, text: []const u8, seen: ?Observer) ![]Token {
    return tokenize(lang, false, a, text, seen);
}
fn tokenize(comptime lang: Syntax, comptime newlines: bool, a: std.mem.Allocator, text: []const u8, seen: ?Observer) ![]Token {
    var out: Stream = .{ .total = text.len };
    // Room at once for a small file: a token in four bytes, up to a few
    // hundred, which a large sparse file never pays for. Under a kilobyte
    // the stream grows as any list does, in blocks no larger than it needs.
    if (text.len >= 1024) try out.list.ensureTotalCapacityPrecise(a, @min(text.len / 4 + 4, 512));
    var i: usize = 0;
    var regex_allowed = true;
    var control_pending = false;
    errdefer out.list.deinit(a);
    var controls: std.ArrayList(bool) = .empty;
    defer controls.deinit(a);
    var templates: std.ArrayList(usize) = .empty;
    defer templates.deinit(a);
    // A leading byte order mark is no part of the text; skipping it keeps
    // every offset a byte offset of the file.
    if (std.mem.startsWith(u8, text, bom)) i = bom.len;
    if ((lang == .groovy or lang == .kotlin) and std.mem.startsWith(u8, text[i..], "#!")) i = lineEnd(text, i);
    while (i < text.len) {
        const start = i;
        const c = text[i];
        if ((lang == .python or lang == .c) and c == '\\' and i + 1 < text.len and text[i + 1] == '\n') {
            i += 2;
            continue;
        }
        if (lang == .javascript and (c == '`' or (c == '}' and templates.items.len > 0 and templates.items[templates.items.len - 1] == 0))) {
            // Retain an opaque boundary so a string inside an interpolation
            // cannot become the literal operand of an enclosing import call.
            try out.push(a, .{ .kind = .template, .text = text[start .. start + 1], .offset = start, .end = start + 1 });
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
        if (try skipTrivia(lang, newlines, a, text, start, &out)) |end| {
            i = end;
            continue;
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
        if (try literal(lang, a, text, start, &out, seen)) |end| {
            i = end;
            regex_allowed = false;
            continue;
        }
        if (identIn(lang, c)) {
            i += 1;
            while (i < text.len and identIn(lang, text[i])) : (i += 1) {}
            const word = text[start..i];
            try out.push(a, .{ .kind = .word, .text = word, .offset = start, .end = i });
            if (seen) |observer| try observer.token(observer.context, out.list.items);
            if (lang == .javascript) {
                const class = js_words.get(word) orelse .other;
                control_pending = class == .control;
                regex_allowed = class == .operand;
            }
            continue;
        }
        i += 1;
        try out.push(a, .{ .kind = .punctuation, .text = text[start..i], .offset = start, .end = i });
        if (lang == .javascript) {
            regex_allowed = std.mem.findScalar(u8, "=(:,;!&|?{}", c) != null;
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
    return out.list.toOwnedSlice(a);
}
/// A token stream as it is lexed. It grows by the density of the text read
/// so far, so a long stream moves a few times rather than at every half
/// again, and a sparse text never holds room for tokens it lacks.
const Stream = struct {
    list: std.ArrayList(Token) = .empty,
    /// The length of the text.
    total: usize,
    fn push(s: *Stream, a: std.mem.Allocator, token: Token) !void {
        std.debug.assert(token.offset < token.end);
        std.debug.assert(token.end <= s.total);
        if (s.list.items.len > 0) std.debug.assert(s.list.items[s.list.items.len - 1].end <= token.offset);
        if (s.list.items.len == s.list.capacity) try s.grow(a, token.end);
        s.list.appendAssumeCapacity(token);
    }
    fn grow(s: *Stream, a: std.mem.Allocator, read: usize) !void {
        @branchHint(.unlikely);
        const n = s.list.items.len;
        // A short stream has too little behind it to project from.
        if (n < 512) return s.list.ensureUnusedCapacity(a, 1);
        const projected = @as(u128, n) * s.total / @max(read, 1);
        // Between half again and four times what is held.
        const least = n + n / 2 + 16;
        const most = 4 * n + 16;
        try s.list.ensureTotalCapacityPrecise(a, @intCast(@min(@max(projected, least), most)));
    }
};
/// The UTF-8 byte order mark, which editors on Windows put first.
pub const bom = "\xEF\xBB\xBF";
fn ident(c: u8) bool {
    return words[c];
}
/// JavaScript words that decide whether a following `/` starts a regular
/// expression: an operand may follow these keywords, and the parenthesis
/// after a control keyword closes a condition.
const js_words = std.StaticStringMap(enum { control, operand, other }).initComptime(.{
    .{ "if", .control },     .{ "while", .control },      .{ "for", .control },    .{ "with", .control },
    .{ "switch", .control }, .{ "catch", .control },      .{ "return", .operand }, .{ "throw", .operand },
    .{ "case", .operand },   .{ "else", .operand },       .{ "do", .operand },     .{ "yield", .operand },
    .{ "await", .operand },  .{ "typeof", .operand },     .{ "void", .operand },   .{ "delete", .operand },
    .{ "in", .operand },     .{ "instanceof", .operand },
});
/// Name bytes, and whitespace other than the newline a stream can keep,
/// by table: the scan loop asks for every byte.
const words = blk: {
    var t: [256]bool = undefined;
    for (&t, 0..) |*v, c| v.* = std.ascii.isAlphanumeric(c) or c == '_' or c == '$' or c >= 128;
    break :blk t;
};
const space = blk: {
    var t: [256]bool = undefined;
    for (&t, 0..) |*v, c| v.* = c != '\n' and std.ascii.isWhitespace(c);
    break :blk t;
};
/// `$` is an operator in Nim, not part of a name.
fn identIn(comptime lang: Syntax, c: u8) bool {
    return ident(c) and !(lang == .nim and c == '$');
}
fn lineEnd(t: []const u8, i: usize) usize {
    return std.mem.findScalarPos(u8, t, i, '\n') orelse t.len;
}
/// Nim block comments `#[ ]#` and `##[ ]##` nest.
fn nimComment(t: []const u8, start: usize) usize {
    var i = start + (if (t[start + 1] == '#') @as(usize, 3) else 2);
    var depth: usize = 1;
    while (i < t.len) {
        if (std.mem.startsWith(u8, t[i..], "#[")) {
            depth += 1;
            i += 2;
        } else if (std.mem.startsWith(u8, t[i..], "]#")) {
            depth -= 1;
            i += 2;
            if (depth == 0) return i;
        } else i += 1;
    }
    return t.len;
}
/// The end of a Java text block or a Groovy or Kotlin triple-quoted string.
fn blockEnd(t: []const u8, from: usize, quote: []const u8, escapes: bool) usize {
    var i = from;
    while (i < t.len) {
        if (escapes and t[i] == '\\') {
            i += 2;
            continue;
        }
        if (std.mem.startsWith(u8, t[i..], quote)) return i + quote.len;
        i += 1;
    }
    return t.len;
}
const Scanned = struct { end: usize, closed: bool, code: bool };
/// A Groovy or Kotlin double-quoted string, whose `${…}` code can hold
/// braces and further strings. Nesting is kept on an explicit stack, so
/// source depth never consumes the call stack.
fn interpolation(a: std.mem.Allocator, t: []const u8, from: usize) !Scanned {
    const Frame = union(enum) { string, code: usize };
    var frames: std.ArrayList(Frame) = .empty;
    defer frames.deinit(a);
    try frames.append(a, .string);
    var code = false;
    var i = from;
    while (i < t.len) {
        const c = t[i];
        switch (frames.items[frames.items.len - 1]) {
            .string => {
                if (c == '\\') {
                    i += 2;
                    continue;
                }
                if (c == '\n' and frames.items.len == 1) break;
                if (c == '"') {
                    _ = frames.pop();
                    i += 1;
                    if (frames.items.len == 0) return .{ .end = i, .closed = true, .code = code };
                    continue;
                }
                if (c == '$' and i + 1 < t.len and t[i + 1] == '{') {
                    code = true;
                    try frames.append(a, .{ .code = 1 });
                    i += 2;
                    continue;
                }
                if (c == '$' and i + 1 < t.len and (std.ascii.isAlphabetic(t[i + 1]) or t[i + 1] == '_')) code = true;
                i += 1;
            },
            .code => |*depth| {
                if (c == '{') depth.* += 1;
                if (c == '}') {
                    depth.* -= 1;
                    if (depth.* == 0) _ = frames.pop();
                } else if (c == '"') {
                    try frames.append(a, .string);
                } else if (c == '\'') {
                    // A Kotlin character or a Groovy single-quoted string.
                    i += 1;
                    while (i < t.len and t[i] != '\'' and t[i] != '\n') : (i += if (t[i] == '\\') 2 else 1) {}
                }
                i += 1;
            },
        }
    }
    return .{ .end = @min(i, t.len), .closed = false, .code = code };
}
fn tripleEnd(t: []const u8, from: usize, quote: []const u8) usize {
    const close = std.mem.findPos(u8, t, from, quote) orelse return t.len;
    var end = close + quote.len;
    // Nim keeps extra quotes before the closing three inside the string.
    while (end < t.len and t[end] == quote[0]) : (end += 1) {}
    return end;
}
fn nimRawEnd(t: []const u8, from: usize) usize {
    var i = from;
    while (i < t.len and t[i] != '\n') : (i += 1) {
        if (t[i] != '"') continue;
        if (i + 1 < t.len and t[i + 1] == '"') {
            i += 1;
            continue;
        }
        return i + 1;
    }
    return i;
}
fn nimCharEnd(t: []const u8, i: usize) ?usize {
    if (i > 0 and std.ascii.isAlphanumeric(t[i - 1])) return null;
    if (i + 1 < t.len and t[i + 1] == '\\') {
        var end = i + 3;
        while (end < t.len and end < i + 12 and t[end] != '\'' and t[end] != '\n') : (end += 1) {}
        return if (end < t.len and t[end] == '\'') end + 1 else null;
    }
    if (i + 2 < t.len and t[i + 1] != '\n' and t[i + 2] == '\'') return i + 3;
    return null;
}
/// Drop newlines for languages where a declaration freely spans lines.
/// Works in place: the stream shrinks rather than being copied.
pub fn compact(tokens: []Token) []Token {
    var n: usize = 0;
    for (tokens) |t| if (t.kind != .newline) {
        tokens[n] = t;
        n += 1;
    };
    return tokens[0..n];
}
/// Decode the ordinary escapes shared by JS, Go and manifest literals.
/// Unsupported escapes are an error rather than an invented path.
pub fn decode(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    return decodeImpl(a, text, false);
}
pub fn decodeJs(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    return decodeImpl(a, text, true);
}
fn decodeImpl(a: std.mem.Allocator, text: []const u8, javascript: bool) ![]const u8 {
    if (std.mem.findScalar(u8, text, '\\') == null) return text;
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
            'b' => try out.append(a, 8),
            'f' => try out.append(a, 12),
            'v' => try out.append(a, 11),
            '0' => try out.append(a, 0),
            'x', 'u', 'U' => {
                const escape = text[i];
                const brace = javascript and escape == 'u' and i + 1 < text.len and text[i + 1] == '{';
                const begin = i + (if (brace) @as(usize, 2) else 1);
                const finish = if (brace) std.mem.findScalarPos(u8, text, begin, '}') orelse return error.InvalidEscape else begin + (if (escape == 'x') @as(usize, 2) else if (escape == 'u') @as(usize, 4) else 8);
                if (finish > text.len or finish == begin) return error.InvalidEscape;
                var code = std.fmt.parseInt(u21, text[begin..finish], 16) catch return error.InvalidEscape;
                i = if (brace) finish else finish - 1;
                if (javascript and !brace and escape == 'u' and code >= 0xd800 and code <= 0xdbff) {
                    if (i + 7 > text.len or !std.mem.eql(u8, text[i + 1 .. i + 3], "\\u")) return error.InvalidEscape;
                    const low = std.fmt.parseInt(u21, text[i + 3 .. i + 7], 16) catch return error.InvalidEscape;
                    if (low < 0xdc00 or low > 0xdfff) return error.InvalidEscape;
                    code = 0x10000 + (code - 0xd800) * 0x400 + (low - 0xdc00);
                    i += 6;
                }
                if (escape == 'x' and !javascript) try out.append(a, @intCast(code)) else {
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(code, &buf) catch return error.InvalidEscape;
                    try out.appendSlice(a, buf[0..len]);
                }
            },
            else => if (javascript) try out.append(a, text[i]) else return error.InvalidEscape,
        }
    }
    return out.toOwnedSlice(a);
}

/// Whitespace, comments, and opaque raw literals never produce operands.
fn skipTrivia(comptime lang: Syntax, comptime newlines: bool, a: std.mem.Allocator, text: []const u8, start: usize, out: *Stream) !?usize {
    std.debug.assert(start < text.len);
    var i = start;
    const c = text[i];
    if (c == '\n') {
        i += 1;
        if (newlines) try out.push(a, .{ .kind = .newline, .text = text[start..i], .offset = start, .end = i });
        return i;
    }
    if (space[c]) {
        i += 1;
        while (i < text.len and space[text[i]]) : (i += 1) {}
        return i;
    }
    if (lang == .nim and c == '#' and (std.mem.startsWith(u8, text[i..], "#[") or std.mem.startsWith(u8, text[i..], "##["))) {
        i = nimComment(text, i);
        return i;
    }
    if ((lang == .python or lang == .nim) and c == '#') {
        i = lineEnd(text, i);
        return i;
    }
    const slashes = lang != .python and lang != .nim;
    if (slashes and i + 1 < text.len and c == '/' and text[i + 1] == '/') {
        i = lineEnd(text, i);
        return i;
    }
    if (slashes and lang != .zig and i + 1 < text.len and c == '/' and text[i + 1] == '*') {
        i += 2;
        var depth: usize = 1;
        while (i < text.len and depth > 0) {
            if (i + 1 < text.len and text[i] == '*' and text[i + 1] == '/') {
                depth -= 1;
                i += 2;
            } else if ((lang == .rust or lang == .kotlin) and i + 1 < text.len and text[i] == '/' and text[i + 1] == '*') {
                depth += 1;
                i += 2;
            } else {
                if (newlines and lang == .c and text[i] == '\n') try out.push(a, .{ .kind = .newline, .text = text[i .. i + 1], .offset = i, .end = i + 1 });
                i += 1;
            }
        }
        return i;
    }
    if (lang == .zig and c == '\\' and i + 1 < text.len and text[i + 1] == '\\') {
        i = lineEnd(text, i);
        return i;
    }
    // Rust raw strings and C++ raw string literals.
    if (lang == .rust and (c == 'r' or (c == 'b' and i + 1 < text.len and text[i + 1] == 'r'))) {
        const prefix: usize = if (c == 'b') 2 else 1;
        var q = i + prefix;
        while (q < text.len and text[q] == '#') : (q += 1) {}
        if (q < text.len and text[q] == '"') {
            const hashes = q - i - prefix;
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
            return i;
        }
    }
    if (lang == .c) {
        const prefix: ?usize = if (std.mem.startsWith(u8, text[i..], "R\"")) 2 else if (std.mem.startsWith(u8, text[i..], "u8R\"")) 4 else if (std.mem.startsWith(u8, text[i..], "uR\"") or std.mem.startsWith(u8, text[i..], "UR\"") or std.mem.startsWith(u8, text[i..], "LR\"")) 3 else null;
        if (prefix) |width| {
            // A delimiter is at most 16 bytes: look no further for its `(`.
            const window = text[0..@min(text.len, i + width + 17)];
            const open = std.mem.findScalarPos(u8, window, i + width, '(') orelse text.len;
            if (open < text.len) {
                const delimiter = text[i + width .. open];
                i = open + 1;
                while (i < text.len) : (i += 1) {
                    if (text[i] == ')' and std.mem.startsWith(u8, text[i + 1 ..], delimiter) and i + 1 + delimiter.len < text.len and text[i + 1 + delimiter.len] == '"') {
                        i += delimiter.len + 2;
                        break;
                    }
                }
                return i;
            }
        }
    }
    return null;
}

/// Quoted operands and interpolation boundaries, with source offsets intact.
fn literal(comptime lang: Syntax, a: std.mem.Allocator, text: []const u8, start: usize, out: *Stream, seen: ?Observer) !?usize {
    var i = start;
    const c = text[i];
    if (lang == .nim and c == '"' and (std.mem.startsWith(u8, text[i..], "\"\"\"") or (i > 0 and ident(text[i - 1])))) {
        // Triple-quoted and prefixed strings are raw: `\` is a byte and a
        // prefixed one doubles its quote. A prefix like `fmt` makes a call.
        const triple = std.mem.startsWith(u8, text[i..], "\"\"\"");
        i = if (triple) tripleEnd(text, i + 3, "\"\"\"") else nimRawEnd(text, i + 1);
        if (!triple) try out.push(a, .{ .kind = .template, .text = text[start..i], .offset = start, .end = i });
        return i;
    }
    if ((lang == .java or lang == .groovy or lang == .kotlin) and (std.mem.startsWith(u8, text[i..], "\"\"\"") or (lang == .groovy and std.mem.startsWith(u8, text[i..], "'''")))) {
        // Text blocks and triple-quoted strings are never plain operands.
        i = blockEnd(text, i + 3, text[i .. i + 3], lang != .kotlin);
        return i;
    }
    if ((lang == .groovy or lang == .kotlin) and c == '"') {
        const scanned = try interpolation(a, text, i + 1);
        i = scanned.end;
        if (scanned.closed) try out.push(a, .{ .kind = if (scanned.code) .template else .string, .text = text[start + 1 .. i - 1], .offset = start, .end = i });
        return i;
    }
    if (lang == .kotlin and c == '`') {
        // A backquoted Kotlin name is a word.
        const close = std.mem.indexOfAnyPos(u8, text, i + 1, "`\n") orelse text.len;
        if (close < text.len and text[close] == '`') {
            try out.push(a, .{ .kind = .word, .text = text[i + 1 .. close], .offset = start, .end = close + 1 });
            i = close + 1;
            return i;
        }
    }
    if (lang == .nim and c == '\'') {
        // A quote after a number starts a type suffix (`1'i8`), not a character.
        if (nimCharEnd(text, i)) |end| {
            i = end;
            return i;
        }
    }
    if (c == '"' or (c == '\'' and lang != .nim) or ((lang == .go or lang == .javascript) and c == '`')) {
        // A Rust lifetime is an identifier, not a character literal.
        if (lang == .rust and c == '\'' and i + 1 < text.len and ident(text[i + 1])) {
            var end = i + 2;
            while (end < text.len and ident(text[end])) : (end += 1) {}
            if (end == text.len or text[end] != '\'') {
                i += 1;
                return i;
            }
        }
        const triple = lang == .python and i + 2 < text.len and text[i + 1] == c and text[i + 2] == c;
        // Only these literals run across lines. Any other quote left open
        // at a newline (an apostrophe in JSX text or `#if 0` prose) ends
        // there, so the rest of the file is still read as code.
        const multiline = triple or c == '`' or (lang == .rust and c == '"');
        const width: usize = if (triple) 3 else 1;
        i += width;
        const content = i;
        while (i < text.len) {
            if (!(lang == .go and c == '`') and text[i] == '\\') {
                i = @min(i + 2, text.len);
                continue;
            }
            if (!multiline and text[i] == '\n') break;
            if (text[i] == c and (!triple or (i + 2 < text.len and text[i + 1] == c and text[i + 2] == c))) break;
            i += 1;
        }
        const end = i;
        const closed = i < text.len and text[i] == c;
        if (closed) i = @min(i + width, text.len);
        const character = c == '\'' and (lang == .zig or lang == .c or lang == .rust or lang == .java or lang == .kotlin);
        if (closed and !triple and !character and !(lang == .javascript and c == '`')) {
            try out.push(a, .{ .kind = .string, .text = text[content..end], .offset = start, .end = i });
            if (seen) |observer| try observer.token(observer.context, out.list.items);
        }
        return i;
    }
    return null;
}

comptime {
    std.debug.assert(space.len == 1 << @bitSizeOf(u8));
}
