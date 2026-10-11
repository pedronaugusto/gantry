//! A validator for the JSON Schema (draft 04) keywords the SARIF 2.1.0 schema
//! uses, so the tests can hold SARIF output to the schema the OASIS technical
//! committee publishes without a tool outside Zig.
//!
//! Checked: `$ref` into `#/definitions`, `type`, `enum`, `properties`,
//! `required`, `additionalProperties`, `items`, `minItems`, `uniqueItems`,
//! `minimum`, `maximum`, `oneOf`, `anyOf` and `allOf`. `format` is read as an
//! annotation, as the reference validators read it unless asked otherwise,
//! and so are `default`, `description`, `title`, `id`, `$schema` and
//! `definitions`. A keyword this does not know is `error.UnsupportedSchema`,
//! and so is a `pattern` that has a string to match: nothing here silently
//! stops checking.
const std = @import("std");

pub const Error = error{ SchemaViolation, UnsupportedSchema } || std.mem.Allocator.Error;

threadlocal var said: [512]u8 = undefined;
threadlocal var said_len: usize = 0;

/// Keeps the reason for the failure being returned, for `reason`: a check that
/// is expected to fail must not write to stderr, where a passing run shows it.
pub fn say(comptime format: []const u8, args: anytype) void {
    var w: std.Io.Writer = .fixed(&said);
    // glint-ignore: Z026 -- a reason longer than the buffer is cut where it ends, and the cut text still says what failed
    w.print(format, args) catch {};
    said_len = w.end;
}

/// Why the last check on this thread failed.
pub fn reason() []const u8 {
    return said[0..said_len];
}

/// `instance` as JSON text, against `schema` as JSON text.
pub fn validate(gpa: std.mem.Allocator, schema: []const u8, instance: []const u8) Error!void {
    var schema_doc = parse(gpa, schema) catch |err| return err;
    defer schema_doc.deinit();
    var instance_doc = parse(gpa, instance) catch |err| return err;
    defer instance_doc.deinit();
    var validator: Validator = .{ .root = schema_doc.value, .gpa = gpa };
    try validator.check(schema_doc.value, instance_doc.value, "#");
}

fn parse(gpa: std.mem.Allocator, text: []const u8) Error!std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, gpa, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => {
            say("schema: not JSON: {t}", .{err});
            return error.SchemaViolation;
        },
    };
}

const Validator = struct {
    root: std.json.Value,
    gpa: std.mem.Allocator,
    /// Matching one of several alternatives is not a failure to report.
    quiet: bool = false,

    fn violation(v: *const Validator, comptime format: []const u8, args: anytype) Error {
        if (!v.quiet) say("schema: " ++ format, args);
        return error.SchemaViolation;
    }

    fn matches(v: *Validator, node: std.json.Value, instance: std.json.Value, path: []const u8) Error!bool {
        const was = v.quiet;
        v.quiet = true;
        defer v.quiet = was;
        v.check(node, instance, path) catch |err| switch (err) {
            error.SchemaViolation => return false,
            else => |e| return e,
        };
        return true;
    }

    fn check(v: *Validator, node: std.json.Value, instance: std.json.Value, path: []const u8) Error!void {
        if (node != .object) return error.UnsupportedSchema;
        var keys = node.object.iterator();
        while (keys.next()) |entry| {
            const key = entry.key_ptr.*;
            const value = entry.value_ptr.*;
            if (std.mem.eql(u8, key, "$ref")) {
                return v.check(try v.resolve(value), instance, path);
            } else if (std.mem.eql(u8, key, "type")) {
                try v.typeOf(value, instance, path);
            } else if (std.mem.eql(u8, key, "enum")) {
                if (value != .array) return error.UnsupportedSchema;
                var allowed = false;
                for (value.array.items) |option| allowed = allowed or equal(option, instance);
                if (!allowed) return v.violation("{s}: not one of the allowed values", .{path});
            } else if (std.mem.eql(u8, key, "required")) {
                if (instance != .object) continue;
                if (value != .array) return error.UnsupportedSchema;
                for (value.array.items) |name| {
                    if (name != .string) return error.UnsupportedSchema;
                    if (!instance.object.contains(name.string)) return v.violation("{s}: required '{s}' is missing", .{ path, name.string });
                }
            } else if (std.mem.eql(u8, key, "properties")) {
                if (instance != .object) continue;
                if (value != .object) return error.UnsupportedSchema;
                var present = instance.object.iterator();
                while (present.next()) |property| {
                    const property_schema = value.object.get(property.key_ptr.*) orelse continue;
                    const inner = try v.gpa.print("{s}/{s}", .{ path, property.key_ptr.* });
                    defer v.gpa.free(inner);
                    try v.check(property_schema, property.value_ptr.*, inner);
                }
            } else if (std.mem.eql(u8, key, "additionalProperties")) {
                if (instance != .object) continue;
                const declared = if (node.object.get("properties")) |p| (if (p == .object) p.object else null) else null;
                var present = instance.object.iterator();
                while (present.next()) |property| {
                    if (declared) |names| if (names.contains(property.key_ptr.*)) continue;
                    switch (value) {
                        .bool => |allowed| if (!allowed) return v.violation("{s}: '{s}' is not a property of it", .{ path, property.key_ptr.* }),
                        .object => {
                            const inner = try v.gpa.print("{s}/{s}", .{ path, property.key_ptr.* });
                            defer v.gpa.free(inner);
                            try v.check(value, property.value_ptr.*, inner);
                        },
                        else => return error.UnsupportedSchema,
                    }
                }
            } else if (std.mem.eql(u8, key, "items")) {
                if (instance != .array) continue;
                for (instance.array.items, 0..) |item, index| {
                    const inner = try v.gpa.print("{s}/{d}", .{ path, index });
                    defer v.gpa.free(inner);
                    try v.check(value, item, inner);
                }
            } else if (std.mem.eql(u8, key, "minItems")) {
                if (instance == .array and instance.array.items.len < try count(value)) return v.violation("{s}: fewer than {d} items", .{ path, try count(value) });
            } else if (std.mem.eql(u8, key, "uniqueItems")) {
                if (instance != .array or value != .bool or !value.bool) continue;
                const items = instance.array.items;
                for (items, 0..) |first, i| for (items[i + 1 ..]) |second| {
                    if (equal(first, second)) return v.violation("{s}: items are not unique", .{path});
                };
            } else if (std.mem.eql(u8, key, "minimum") or std.mem.eql(u8, key, "maximum")) {
                const number = asFloat(instance) orelse continue;
                const bound = asFloat(value) orelse return error.UnsupportedSchema;
                const low = std.mem.eql(u8, key, "minimum");
                if (if (low) number < bound else number > bound) return v.violation("{s}: {d} is out of the {s} {d}", .{ path, number, key, bound });
            } else if (std.mem.eql(u8, key, "oneOf") or std.mem.eql(u8, key, "anyOf") or std.mem.eql(u8, key, "allOf")) {
                if (value != .array) return error.UnsupportedSchema;
                if (std.mem.eql(u8, key, "allOf")) {
                    for (value.array.items) |option| try v.check(option, instance, path);
                    continue;
                }
                var matched: usize = 0;
                for (value.array.items) |option| {
                    if (try v.matches(option, instance, path)) matched += 1;
                }
                const one = std.mem.eql(u8, key, "oneOf");
                if (matched == 0 or (one and matched > 1)) return v.violation("{s}: matches {d} of the {s} alternatives", .{ path, matched, key });
            } else if (std.mem.eql(u8, key, "pattern")) {
                if (instance == .string) return error.UnsupportedSchema;
            } else if (!annotation(key)) return error.UnsupportedSchema;
        }
    }

    fn typeOf(v: *Validator, value: std.json.Value, instance: std.json.Value, path: []const u8) Error!void {
        switch (value) {
            .string => |name| if (!isType(name, instance)) return v.violation("{s}: not a {s}", .{ path, name }),
            .array => |names| {
                for (names.items) |name| {
                    if (name != .string) return error.UnsupportedSchema;
                    if (isType(name.string, instance)) return;
                }
                return v.violation("{s}: not any of the allowed types", .{path});
            },
            else => return error.UnsupportedSchema,
        }
    }

    /// `#/definitions/name`, the only reference form the schema uses.
    fn resolve(v: *const Validator, ref: std.json.Value) Error!std.json.Value {
        if (ref != .string or !std.mem.startsWith(u8, ref.string, "#/definitions/")) return error.UnsupportedSchema;
        const definitions = v.root.object.get("definitions") orelse return error.UnsupportedSchema;
        if (definitions != .object) return error.UnsupportedSchema;
        return definitions.object.get(ref.string["#/definitions/".len..]) orelse error.UnsupportedSchema;
    }
};

fn annotation(key: []const u8) bool {
    for ([_][]const u8{ "$schema", "id", "title", "description", "default", "format", "definitions" }) |name| {
        if (std.mem.eql(u8, key, name)) return true;
    }
    return false;
}

fn count(value: std.json.Value) Error!usize {
    if (value != .integer or value.integer < 0) return error.UnsupportedSchema;
    return @intCast(value.integer);
}

fn asFloat(value: std.json.Value) ?f64 {
    return switch (value) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

fn isType(name: []const u8, instance: std.json.Value) bool {
    if (std.mem.eql(u8, name, "object")) return instance == .object;
    if (std.mem.eql(u8, name, "array")) return instance == .array;
    if (std.mem.eql(u8, name, "string")) return instance == .string;
    if (std.mem.eql(u8, name, "boolean")) return instance == .bool;
    if (std.mem.eql(u8, name, "null")) return instance == .null;
    if (std.mem.eql(u8, name, "number")) return instance == .integer or instance == .float or instance == .number_string;
    if (std.mem.eql(u8, name, "integer")) return instance == .integer or (instance == .float and @floor(instance.float) == instance.float);
    return false;
}

fn equal(a: std.json.Value, b: std.json.Value) bool {
    if (asFloat(a)) |x| return if (asFloat(b)) |y| x == y else false;
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .bool => |x| x == b.bool,
        .string => |x| std.mem.eql(u8, x, b.string),
        .number_string => |x| std.mem.eql(u8, x, b.number_string),
        .array => |x| {
            if (x.items.len != b.array.items.len) return false;
            for (x.items, b.array.items) |left, right| if (!equal(left, right)) return false;
            return true;
        },
        .object => |x| {
            if (x.count() != b.object.count()) return false;
            var it = x.iterator();
            while (it.next()) |entry| {
                const other = b.object.get(entry.key_ptr.*) orelse return false;
                if (!equal(entry.value_ptr.*, other)) return false;
            }
            return true;
        },
        .integer, .float => unreachable, // unreachable: asFloat took every number above
    };
}

test "the keywords a schema holds an instance to" {
    const a = std.testing.allocator;
    const schema =
        \\{"definitions":{"name":{"type":"string","enum":["x","y"]}},
        \\ "type":"object","required":["n"],"additionalProperties":false,
        \\ "properties":{"n":{"$ref":"#/definitions/name"},
        \\   "list":{"type":"array","minItems":1,"uniqueItems":true,"items":{"type":"integer","minimum":0,"maximum":9}},
        \\   "either":{"oneOf":[{"type":"string"},{"type":"boolean"}]}}}
    ;
    try validate(a, schema, "{\"n\":\"x\",\"list\":[1,2],\"either\":true}");
    for ([_][]const u8{
        "{}",
        "{\"n\":\"z\"}",
        "{\"n\":\"x\",\"extra\":1}",
        "{\"n\":\"x\",\"list\":[]}",
        "{\"n\":\"x\",\"list\":[1,1]}",
        "{\"n\":\"x\",\"list\":[10]}",
        "{\"n\":\"x\",\"list\":[1.5]}",
        "{\"n\":\"x\",\"either\":3}",
        "[]",
    }) |instance| try std.testing.expectError(error.SchemaViolation, validate(a, schema, instance));
}

test "a keyword the validator does not know is refused, not skipped" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.UnsupportedSchema, validate(a, "{\"minLength\":1}", "\"x\""));
    try std.testing.expectError(error.UnsupportedSchema, validate(a, "{\"pattern\":\"^a\"}", "\"a\""));
    try validate(a, "{\"pattern\":\"^a\"}", "1");
}
