//! JSON with comments and trailing commas; source-language syntax stays invalid.
const std = @import("std");

pub fn parse(a: std.mem.Allocator, scratch: std.mem.Allocator, text: []const u8) !std.json.Value {
    const clean = try scratch.dupe(u8, text);
    defer scratch.free(clean);
    var i: usize = 0;
    while (i < clean.len) {
        if (clean[i] == '"') {
            i = stringEnd(clean, i);
            continue;
        }
        if (std.mem.startsWith(u8, clean[i..], "//")) {
            const end = std.mem.indexOfScalarPos(u8, clean, i + 2, '\n') orelse clean.len;
            @memset(clean[i..end], ' ');
            i = end;
        } else if (std.mem.startsWith(u8, clean[i..], "/*")) {
            const end = (std.mem.indexOfPos(u8, clean, i + 2, "*/") orelse return error.SyntaxError) + 2;
            for (clean[i..end]) |*byte| if (byte.* != '\n' and byte.* != '\r') {
                byte.* = ' ';
            };
            i = end;
        } else i += 1;
    }
    i = 0;
    while (i < clean.len) {
        if (clean[i] == '"') {
            i = stringEnd(clean, i);
            continue;
        }
        if (clean[i] == ',') {
            var next = i + 1;
            while (next < clean.len and std.ascii.isWhitespace(clean[next])) : (next += 1) {}
            if (next < clean.len and (clean[next] == '}' or clean[next] == ']')) clean[i] = ' ';
        }
        i += 1;
    }
    // Every way the bytes fail to be JSON is one syntax error.
    return std.json.parseFromSliceLeaky(std.json.Value, a, clean, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.SyntaxError,
    };
}

fn stringEnd(text: []const u8, start: usize) usize {
    var i = start + 1;
    while (i < text.len) {
        if (text[i] == '"') return i + 1;
        if (text[i] == '\\') i = @min(i + 2, text.len) else i += 1;
    }
    // The JSON parser reports an unterminated string.
    return text.len;
}
