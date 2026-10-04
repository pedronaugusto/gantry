//! Scan inputs and language selection, below scanning and the public facade.
const std = @import("std");
const t = @import("types.zig");
const Kind = t.Kind;
const Language = t.Language;
const resolver = @import("resolve.zig");
const NamedModule = resolver.NamedModule;
const GoTarget = @import("go_build.zig").Target;
pub const GoFile = @import("go_build.zig").File;
const PythonInitializers = resolver.PythonInitializers;
const languages = @import("languages.zig");

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
    /// Record the identifiers and string values these rules name, from
    /// source files in a supported language, for `graph.tokens()` and the
    /// same rules in `rules.Rules.tokens`. Only `kind` and `token` are read.
    tokens: []const @import("rules/rules_check.zig").TokenRule = &.{},
};

pub fn languageOf(p: []const u8) ?Language {
    const ext = std.fs.path.extension(p);
    inline for (comptime std.meta.tags(Language)) |lang| {
        for (@field(languages, @tagName(lang)).extensions) |e| if (std.mem.eql(u8, ext, e)) return lang;
    }
    return null;
}
