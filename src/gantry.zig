//! gantry reads caller-selected files and records their dependencies.
//! Managed results own their allocator; slices belong to that result until
//! deinit. There is no global state, git, compiler invocation or thread.
const std = @import("std");
const t = @import("types.zig");
const resolver = @import("resolve.zig");
pub const Graph = @import("Graph.zig").Graph;
pub const Analysis = @import("Analysis.zig").Analysis;
pub const Language = t.Language;
pub const Kind = t.Kind;
pub const Edge = t.Edge;
pub const Reference = t.Reference;
pub const Dependency = t.Dependency;
pub const Layer = t.Layer;
pub const Cycle = t.Cycle;
pub const Spec = t.Spec;
pub const PythonInitializers = resolver.PythonInitializers;
pub const GoTarget = @import("go_build.zig").Target;
pub const GoFile = @import("go_build.zig").File;
pub const NamedModule = resolver.NamedModule;
pub const rules = @import("rules.zig");
pub const manifests = @import("manifests.zig");
pub const path = @import("path.zig");
const languages = @import("languages.zig");
pub const Options = struct {
    kinds: []const Kind = &.{ .import, .@"test" },
    manifests: bool = true,
    named_modules: []const NamedModule = &.{},
    include_roots: []const []const u8 = &.{},
    python_roots: []const []const u8 = &.{""},
    go_target: ?GoTarget = null,
    python_initializers: PythonInitializers = .ancestors,
    python_star_reexports: bool = true,
};
pub fn languageOf(p: []const u8) ?Language {
    const ext = std.fs.path.extension(p);
    inline for (comptime std.meta.tags(Language)) |lang| {
        for (@field(languages, @tagName(lang)).extensions) |e| if (std.mem.eql(u8, ext, e)) return lang;
    }
    return null;
}
/// Raw lexical references, owning source bytes and every slice until deinit.
pub const Imports = @import("scan.zig").Imports;
pub const imports = @import("scan.zig").imports;
/// read(context, path, scratch_allocator) returns !?[]const u8. Bytes need
/// only survive processing until the next read. Null records an unread path;
/// an error aborts without a partial graph. Scratch is released per file.
/// The returned graph borrows neither input paths and options nor file bytes.
pub const scan = @import("scan.zig").scan;
/// The same atomic scan, with a caller-owned file, phase and cause on failure.
pub const scanWithDiagnostic = @import("scan.zig").scanWithDiagnostic;
pub const ScanDiagnostic = @import("scan_diagnostic.zig").ScanDiagnostic;
/// Reader over an already-open directory; directory ownership stays with caller.
/// The byte limit is caller policy. A missing selected file is an I/O error.
pub const DirReader = struct {
    io: std.Io,
    dir: std.Io.Dir,
    limit: std.Io.Limit = .unlimited,
    pub fn read(self: DirReader, p: []const u8, a: std.mem.Allocator) !?[]const u8 {
        return try self.dir.readFileAlloc(self.io, p, a, self.limit);
    }
};
/// Convenience listing. keep(context, slash_path, entry_kind) may prune a
/// directory; no ignore policy is imposed. Paths own their allocator.
pub const Paths = @import("scan.zig").Paths;
pub const walk = @import("scan.zig").walk;

test {
    _ = @import("tests.zig");
}
