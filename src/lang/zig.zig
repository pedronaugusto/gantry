//! Zig's files and what an `@import` names. Reading them is a frontend's
//! work (`gantry.zig`), so this module has no lexer and no dependency.
const std = @import("std");
const types = @import("../types.zig");
const Spec = types.Spec;
const p = @import("../path.zig");
pub fn resolve(c: anytype, from: []const u8, spec: Spec) types.ResolveError![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const a = c.allocator;
    const dir = p.dir(from);
    const name = spec.name;
    // A `.zig` or `.zon` name is a file beside the importer; any other a module.
    if (std.mem.endsWith(u8, name, ".zig") or std.mem.endsWith(u8, name, ".zon")) {
        if (try c.candidate(dir, name, &.{""})) |v| try out.append(a, v);
    } else for (c.named_modules, c.named_from) |m, named_from| {
        if (std.mem.eql(u8, name, m.name) and named_from.matches(from)) {
            if (try c.candidate("", m.path, &.{""})) |v| try out.append(a, v);
            break;
        }
    }
    return out.toOwnedSlice(a);
}
pub const extensions = &[_][]const u8{".zig"};
