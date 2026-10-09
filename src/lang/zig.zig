//! Zig facts come from glint, which reads a file with std's own parser and
//! lowering. This module adapts them to gantry's references and owns what
//! gantry decides: how a spelling resolves to a file.
const std = @import("std");
const glint = @import("glint");
const l = @import("../lexer.zig");
const liveness = @import("zig/liveness.zig");
const types = @import("../types.zig");
const Spec = types.Spec;

/// The token stream the token rules read; `seen` observes it as it grows.
pub fn lex(arena: std.mem.Allocator, source: []const u8, seen: ?l.Observer) std.mem.Allocator.Error![]const l.Token {
    return l.lexCompact(.zig, arena, source, seen);
}

/// `InvalidSource` is a file std's parser or lowering rejects, or one past
/// the front end's size and nesting limits: it has no facts, and none are guessed.
pub const RecoverError = error{ InvalidSource, OutOfMemory };

/// The imports of `source` and the members read from them, with the kind each
/// has and whether any build analyses it. `gpa` holds the front end while it
/// runs; the result is in `arena`.
pub fn recover(gpa: std.mem.Allocator, arena: std.mem.Allocator, source: []const u8) RecoverError!types.Recovery {
    // Zig source is UTF-8, and std's lowering of a character literal that ends in
    // a cut sequence (`'\xf0'`) indexes past it: a panic with safety checks.
    // Bytes that are not UTF-8 are not Zig.
    if (!std.unicode.utf8ValidateSlice(source)) return error.InvalidSource;
    var project = glint.Project.init(gpa, &.{.{ .name = "", .bytes = source }}, &.{}, .{}) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.SourceTooLarge, error.SourceTooComplex, error.InvalidIdentifier, error.ProjectBudgetExceeded, error.SnapshotLimit => error.InvalidSource,
        // unreachable: the project is given no module mappings.
        error.InvalidMapping, error.DuplicateMapping => unreachable,
    };
    defer project.deinit();
    const file = glint.Project.FileId.fromRaw(0);
    const handle = project.handle(file) catch unreachable; // unreachable: file zero is the project's one source.
    if ((project.status(handle) catch unreachable) != .parsed) return error.InvalidSource; // unreachable: as above.
    const tree = project.syntax(handle) catch unreachable; // unreachable: as above.
    // Every node resolves at most once, so this budget is never the limit.
    var projection = glint.Projection.init(gpa, &project, tree.nodes.len + 64) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidIdentifier => error.InvalidSource,
        // unreachable: the project is the one the handle came from.
        error.InvalidHandle => unreachable,
    };
    defer projection.deinit();
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    return liveness.read(arena, scratch.allocator(), .{
        .project = &project,
        .file = file,
        .tree = tree,
        .declarations = project.declarations(handle) catch unreachable, // unreachable: as above.
        .projection = &projection,
    });
}

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
