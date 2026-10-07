//! Token rule occurrences, taken from the token streams recovery lexes anyway.
const check_module = @import("rules/check.zig");
const std = @import("std");
const sweep = @import("sweep");
const t = @import("types.zig");
const l = @import("lexer.zig");
const TokenRule = check_module.TokenRule;

/// Collects the identifiers and string values the rules name, at most once
/// per file. With no rules every call returns at once.
pub const Recorder = struct {
    rules: []const TokenRule = &.{},
    /// Every rule's tokens compiled, with the kind each names.
    patterns: []const Named = &.{},
    /// Graph storage for matched text.
    strings: std.mem.Allocator = undefined,
    found: std.ArrayList(t.Token) = .empty,
    /// Files already recorded, by graph path position.
    done: []bool = &.{},
    filters: [2]Filter = .{ .{}, .{} },
    /// The file being lexed, which `observer` points the lexer at.
    current: File = undefined,

    sequences: []const []const *const sweep.Pattern = &.{},
    endings: Filter = .{},

    const Named = struct { kind: t.Token.Kind, pattern: *const sweep.Pattern };

    pub fn init(w: std.mem.Allocator, strings: std.mem.Allocator, rules: []const TokenRule, globs: *check_module.Globs, files: usize) sweep.CompileError!Recorder {
        if (rules.len == 0) return .{};
        const done = try w.alloc(bool, files);
        @memset(done, false);
        var patterns: std.ArrayList(Named) = .empty;
        for (rules) |rule| for (rule.tokens) |token| try patterns.append(w, .{ .kind = rule.kind, .pattern = try globs.get(.token, token) });
        var r: Recorder = .{ .rules = rules, .patterns = patterns.items, .strings = strings, .done = done };
        for (rules) |rule| {
            if (rule.kind == .sequence) return error.InvalidPattern;
            for (rule.tokens) |token| r.filters[@backingInt(rule.kind)].add(token);
        }
        var sequences: std.ArrayList([]const *const sweep.Pattern) = .empty;
        for (rules) |rule| for (rule.sequences) |sequence| {
            try sequences.append(w, try globs.sequence(sequence));
            r.endings.add(sequence[sequence.len - 1]);
        };
        r.sequences = sequences.items;
        return r;
    }
    pub fn active(r: *const Recorder) bool {
        return r.rules.len > 0;
    }
    /// Whether `index` still needs its token stream.
    pub fn wants(r: *const Recorder, index: usize) bool {
        return r.rules.len > 0 and !r.done[index];
    }
    /// `module.lex` of a file's source, recording rule tokens as the lexer
    /// emits them when this file still wants them. `scratch` holds decoded
    /// strings until the file's scratch is released; matches are copied
    /// into graph storage.
    pub fn lex(r: *Recorder, comptime module: type, scratch: std.mem.Allocator, index: usize, path: []const u8, language: t.Language, source: []const u8) std.mem.Allocator.Error![]const l.Token {
        return module.lex(scratch, source, r.observer(scratch, index, path, language, source));
    }
    /// The observer that records file `index` while it is lexed, or null
    /// when it is recorded already or there are no rules. Valid until the
    /// next call.
    pub fn observer(r: *Recorder, scratch: std.mem.Allocator, index: usize, path: []const u8, language: t.Language, source: []const u8) ?l.Observer {
        if (!r.wants(index)) return null;
        r.done[index] = true;
        r.current = .{ .recorder = r, .scratch = scratch, .path = path, .language = language, .source = source };
        return .{ .context = &r.current, .token = if (r.sequences.len > 0) File.sequenceToken else File.token, .punctuation = r.sequences.len > 0 };
    }
    /// Occurrences by path and offset, in graph storage.
    pub fn finish(r: *Recorder) std.mem.Allocator.Error![]const t.Token {
        if (!r.active()) return &.{};
        std.mem.sort(t.Token, r.found.items, {}, struct {
            fn less(_: void, x: t.Token, y: t.Token) bool {
                const order = std.mem.order(u8, x.path, y.path);
                return order == .lt or (order == .eq and x.offset < y.offset);
            }
        }.less);
        return r.found.toOwnedSlice(r.strings);
    }
};

/// One file's observer: each word or string is checked as it is lexed,
/// with the stream so far for the token before it.
const File = struct {
    recorder: *Recorder,
    scratch: std.mem.Allocator,
    path: []const u8,
    language: t.Language,
    source: []const u8,
    line: usize = 1,
    line_start: usize = 0,
    counted: usize = 0,

    fn token(context: *anyopaque, tokens: []const l.Token) error{OutOfMemory}!void {
        const f: *File = @ptrCast(@alignCast(context)); // safe: `observer` hands the lexer the recorder's own File as the context.
        const r = f.recorder;
        const i = tokens.len - 1;
        const current = tokens[i];
        var kind: t.Token.Kind = undefined;
        var text: []const u8 = undefined;
        if (current.kind == .word) {
            if (!r.filters[@backingInt(t.Token.Kind.identifier)].admits(current.text) or std.ascii.isDigit(current.text[0])) return;
            kind = .identifier;
            text = current.text;
        } else {
            kind = if (f.language == .zig and quoted(tokens, i)) .identifier else .string;
            const filter = &r.filters[@backingInt(kind)];
            if (filter.empty()) return;
            // Go runes are not strings.
            if (f.language == .go and f.source[current.offset] == '\'') return;
            text = try value(f.scratch, f.language, current.text, raw(f.language, f.source, tokens, i));
            if (!filter.admits(text)) return;
        }
        for (r.patterns) |named| {
            if (named.kind == kind and named.pattern.matches(text)) break;
        } else return;
        while (f.counted < current.offset) : (f.counted += 1) if (f.source[f.counted] == '\n') {
            f.line += 1;
            f.line_start = f.counted + 1;
        };
        try r.found.append(r.strings, .{
            .path = f.path,
            .kind = kind,
            .text = try r.strings.dupe(u8, text),
            .offset = current.offset,
            .line = f.line,
            .column = current.offset - f.line_start + 1,
        });
    }

    fn sequenceToken(context: *anyopaque, tokens: []const l.Token) error{OutOfMemory}!void {
        const f: *File = @ptrCast(@alignCast(context)); // safe: observer supplies the recorder's own File
        const kind = tokens[tokens.len - 1].kind;
        if (kind == .word or kind == .punctuation) try f.sequences(tokens);
        if (kind == .word or kind == .string) try token(context, tokens);
    }

    fn sequences(f: *File, tokens: []const l.Token) !void {
        const r = f.recorder;
        if (r.sequences.len == 0 or !r.endings.admits(tokens[tokens.len - 1].text)) return;
        const recorded = r.found.items.len;
        for (r.sequences) |sequence| {
            var end = tokens.len;
            var first: usize = end;
            var at = sequence.len;
            while (at > 0) {
                while (end > 0 and tokens[end - 1].kind == .newline) end -= 1;
                if (end == 0) break;
                end -= 1;
                const part = tokens[end];
                if ((part.kind != .word and part.kind != .punctuation) or !sequence[at - 1].matches(part.text)) break;
                first = end;
                at -= 1;
            }
            if (at != 0) continue;
            var text: std.ArrayList(u8) = .empty;
            for (tokens[first..]) |part| {
                if (part.kind == .newline) continue;
                if (text.items.len > 0) try text.append(f.scratch, ' ');
                try text.appendSlice(f.scratch, part.text);
            }
            // Several rules may name the same occurrence.
            for (r.found.items[recorded..]) |found| {
                if (found.kind == .sequence and found.offset == tokens[first].offset and std.mem.eql(u8, found.path, f.path) and std.mem.eql(u8, found.text, text.items)) break;
            } else {
                const offset = tokens[first].offset;
                while (f.counted < offset) : (f.counted += 1) if (f.source[f.counted] == '\n') {
                    f.line += 1;
                    f.line_start = f.counted + 1;
                };
                const back = std.mem.count(u8, f.source[offset..f.counted], "\n");
                const start = if (back == 0) f.line_start else if (std.mem.findScalarLast(u8, f.source[0..offset], '\n')) |n| n + 1 else 0;
                try r.found.append(r.strings, .{
                    .kind = .sequence,
                    .path = f.path,
                    .text = try r.strings.dupe(u8, text.items),
                    .offset = offset,
                    .line = f.line - back,
                    .column = offset - start + 1,
                });
            }
        }
    }
};

/// Rejects most tokens by first byte and length before any pattern runs.
const Filter = struct {
    first: [256]bool = @splat(false),
    any_first: bool = false,
    /// Bit n admits length n; bit 63 admits 63 and longer.
    lengths: u64 = 0,

    fn add(f: *Filter, pattern: []const u8) void {
        var least: usize = 0;
        var open = false;
        for (pattern) |c| {
            if (c == '*') open = true else least += 1;
        }
        if (pattern.len == 0 or pattern[0] == '*' or pattern[0] == '?') f.any_first = true else f.first[pattern[0]] = true;
        if (open) {
            f.lengths |= ~@as(u64, 0) << @intCast(@min(least, 63));
        } else f.lengths |= @as(u64, 1) << @intCast(@min(least, 63));
    }
    fn empty(f: *const Filter) bool {
        return f.lengths == 0;
    }
    fn admits(f: *const Filter, text: []const u8) bool {
        if (f.lengths & (@as(u64, 1) << @intCast(@min(text.len, 63))) == 0) return false;
        return f.any_first or (text.len > 0 and f.first[text[0]]);
    }
};

/// A Zig `@"name"` is an identifier.
fn quoted(tokens: []const l.Token, i: usize) bool {
    return i > 0 and tokens[i - 1].is("@") and tokens[i - 1].end == tokens[i].offset;
}

/// A Go backquoted string or a Python string with an `r` prefix keeps its
/// backslashes.
fn raw(language: t.Language, source: []const u8, tokens: []const l.Token, i: usize) bool {
    const token = tokens[i];
    return switch (language) {
        .go => source[token.offset] == '`',
        .python => i > 0 and tokens[i - 1].kind == .word and tokens[i - 1].end == token.offset and std.mem.findAny(u8, tokens[i - 1].text, "rR") != null,
        else => false,
    };
}

/// A string literal's value: the escapes its language defines, with an
/// unknown escape kept as written. Code points are UTF-8; `\x` is a byte
/// in Zig, C, Go, Rust and Nim and a code point in Python and JavaScript.
pub fn value(arena: std.mem.Allocator, language: t.Language, text: []const u8, keep: bool) std.mem.Allocator.Error![]const u8 {
    if (keep or std.mem.findScalar(u8, text, '\\') == null) return text;
    var out: std.ArrayList(u8) = try .initCapacity(arena, text.len);
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] != '\\' or i + 1 == text.len) {
            out.appendAssumeCapacity(text[i]);
            i += 1;
            continue;
        }
        const c = text[i + 1];
        const simple: ?u8 = switch (c) {
            '\\', '\'', '"' => c,
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            'a' => if (language == .zig or language == .rust) null else 7,
            'b' => if (language == .zig or language == .rust) null else 8,
            'f' => if (language == .zig or language == .rust) null else 12,
            'v' => if (language == .zig or language == .rust or language == .java) null else 11,
            'e' => if (language == .c or language == .nim) 27 else null,
            '?' => if (language == .c) '?' else null,
            // `\0` is NUL there; elsewhere it starts an octal or decimal escape.
            '0' => if (language == .zig or language == .rust or (language == .javascript and !(i + 2 < text.len and std.ascii.isDigit(text[i + 2])))) 0 else null,
            else => null,
        };
        if (simple) |byte| {
            try out.append(arena, byte);
            i += 2;
            continue;
        }
        if (escape(language, text, i)) |decoded| {
            if (decoded.byte) {
                try out.append(arena, @intCast(decoded.code));
            } else {
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(decoded.code, &buf) catch {
                    try out.appendSlice(arena, text[i..decoded.end]);
                    i = decoded.end;
                    continue;
                };
                try out.appendSlice(arena, buf[0..len]);
            }
            i = decoded.end;
            continue;
        }
        try out.appendSlice(arena, text[i .. i + 2]);
        i += 2;
    }
    return out.items;
}
const Escape = struct { code: u21, end: usize, byte: bool };
/// Numeric escapes at `text[i] == '\\'`.
fn escape(language: t.Language, text: []const u8, i: usize) ?Escape {
    const c = text[i + 1];
    const byte_x = language != .python and language != .javascript;
    switch (c) {
        'x' => {
            if (language == .java) return null;
            // C reads every following hex digit; the others exactly two.
            const max: usize = if (language == .c) text.len else i + 4;
            const digits = hexRun(text, i + 2, max);
            if (digits == i + 2 or (language != .c and digits != i + 4)) return null;
            const code = std.fmt.parseInt(u32, text[i + 2 .. digits], 16) catch return null;
            return .{ .code = @intCast(code & 0xff), .end = digits, .byte = byte_x };
        },
        'u', 'U' => {
            if (c == 'u' and i + 2 < text.len and text[i + 2] == '{') {
                if (language != .zig and language != .rust and language != .javascript and language != .nim) return null;
                const close = std.mem.findScalarPos(u8, text, i + 3, '}') orelse return null;
                const code = std.fmt.parseInt(u21, text[i + 3 .. close], 16) catch return null;
                return .{ .code = code, .end = close + 1, .byte = false };
            }
            if (c == 'U' and (language == .zig or language == .rust or language == .javascript or language == .java)) return null;
            if (c == 'u' and (language == .zig or language == .rust)) return null;
            const width: usize = if (c == 'u') 4 else 8;
            if (i + 2 + width > text.len or hexRun(text, i + 2, i + 2 + width) != i + 2 + width) return null;
            const code = std.fmt.parseInt(u21, text[i + 2 .. i + 2 + width], 16) catch return null;
            return .{ .code = code, .end = i + 2 + width, .byte = false };
        },
        '0'...'9' => {
            if (language == .nim) {
                // Nim spells a byte in decimal.
                var end = i + 1;
                while (end < text.len and end < i + 4 and std.ascii.isDigit(text[end])) : (end += 1) {}
                const code = std.fmt.parseInt(u16, text[i + 1 .. end], 10) catch return null;
                if (code > 255) return null;
                return .{ .code = @intCast(code), .end = end, .byte = true };
            }
            if (language == .zig or language == .rust or c > '7') return null;
            var end = i + 1;
            while (end < text.len and end < i + 4 and text[end] >= '0' and text[end] <= '7') : (end += 1) {}
            if (language == .go and end != i + 4) return null;
            const code = std.fmt.parseInt(u16, text[i + 1 .. end], 8) catch return null;
            if (code > 255) return null;
            return .{ .code = @intCast(code), .end = end, .byte = byte_x };
        },
        else => return null,
    }
}
fn hexRun(text: []const u8, from: usize, max: usize) usize {
    var end = from;
    while (end < text.len and end < max and std.ascii.isHex(text[end])) : (end += 1) {}
    return end;
}
