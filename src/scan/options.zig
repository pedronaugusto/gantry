//! Scan inputs and language selection, below scanning and the public facade.
const build_module = @import("../lang/go/build.zig");
const check_module = @import("../rules/check.zig");
const std = @import("std");
const t = @import("../types.zig");
const Kind = t.Kind;
const Language = t.Language;
const resolver = @import("../resolve.zig");
const NamedModule = resolver.NamedModule;
const GoTarget = build_module.Target;
pub const GoFile = build_module.File;
const PythonInitializers = resolver.PythonInitializers;
const languages = @import("../lang.zig");

pub const Options = struct {
    /// The edge kinds to record. References are recorded whatever their kind.
    kinds: []const Kind = &.{ .import, .type_only, .dynamic, .@"test" },
    manifests: bool = true,
    /// Reject detectable unsupported imports in participating source files,
    /// and declarations read manifests cannot read. This also extracts code
    /// when import and test edges are disabled.
    strict_imports: bool = false,
    named_modules: []const NamedModule = &.{},
    include_roots: []const []const u8 = &.{},
    python_roots: []const []const u8 = &.{""},
    go_target: ?GoTarget = null,
    python_initializers: PythonInitializers = .ancestors,
    python_star_reexports: bool = true,
    /// Path patterns (as layer patterns read them) of test files beyond each
    /// language's own conventions: every import of a matching file is `test`.
    /// Zig has no convention, so its callers name theirs (`src/testing/**`).
    test_paths: []const []const u8 = &.{},
    /// Record the identifiers and string values these rules name, from
    /// source files in a supported language, for `graph.tokens()` and the
    /// same rules in `rules.Rules.tokens`. Only `kind` and `token` are read.
    tokens: []const check_module.TokenRule = &.{},
};

pub fn languageOf(p: []const u8) ?Language {
    const ext = std.Io.Dir.path.extension(p);
    inline for (comptime std.meta.tags(Language)) |lang| {
        for (@field(languages, @tagName(lang)).extensions) |e| if (std.mem.eql(u8, ext, e)) return lang;
    }
    return null;
}
