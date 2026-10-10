//! What a language frontend yields to gantry's core, and how a scan reaches it.
//! The vocabulary is below everything else: the core imports it, and a
//! frontend module imports nothing of the core, so both share these types.
const std = @import("std");

/// The source languages import recovery reads.
pub const Language = enum { zig, c, javascript, python, go, rust, nim, java };

/// What an edge or reference is. A source import is `import`, `type_only`,
/// `dynamic` or `test`; a test file's import, or an import of a test file,
/// is `test` whatever its form.
pub const Kind = enum {
    /// A static import, include or `require`.
    import,
    /// A Markdown link.
    link,
    /// A path a text file names.
    asset,
    /// An import in a test file or in code only a test build compiles, or
    /// one a package import makes of a test file (Go, Java, a Rust `mod`).
    @"test",
    /// An import for types alone: a TypeScript `import type`, `export
    /// type`, braces whose every name is marked `type`, `typeof import("x")`
    /// or `import("x").T` in a type; a Python import under `if TYPE_CHECKING:`.
    type_only,
    /// A module loaded when the code runs: JavaScript `import("x")`, Python
    /// `importlib.import_module("x")` and `__import__("x")`.
    dynamic,
};

pub const Form = enum {
    literal,
    python,
    rust_mod,
    rust_use,
    java_static,
    /// A Rust path rooted at a crate's name rather than at `crate`,
    /// `self`, `super` or a module of this file: a `use` path, an
    /// `extern crate`, or the first segment of a path in code.
    rust_crate,
};

/// Raw references borrow the source or the allocator passed to the lexer.
/// `dead` as on `Reference`.
// aegis: no danger there; docs/design.md: lexical offsets are bounded positions in one source slice, with no domain conversion inside recovery.
pub const Spec = struct { name: []const u8, offset: usize, form: Form = .literal, member: ?[]const u8 = null, kind: Kind = .import, scope: []const u8 = "", python_base: bool = false, star: bool = false, dead: bool = false };

/// The lexical construct that recovery could not turn into a reference, or
/// a manifest construct it could not turn into a declaration.
pub const ImportExpression = enum {
    zig_import,
    c_include,
    javascript_import,
    javascript_require,
    /// An `importlib.import_module` call whose names are not literal.
    python_importlib,
    /// A `__import__` call whose name is not a literal.
    python_import,
    rust_include,
    rust_path,
    /// An `import` or `from` operand that is not a module path or string.
    nim_import,
    /// An `include` operand that is not a module path or string.
    nim_include,
    /// A `.nimble` `requires` or `taskRequires` argument that is not a string literal.
    nimble_requires,
    /// `Class.forName(`, which loads a class by a name known at run time.
    java_for_name,
    /// A `.loadClass(` call on a class loader.
    java_load_class,
    /// A `pom.xml` dependency naming a property its file does not define.
    maven_dependency,
    /// A Gradle `dependencies` statement that is not a literal declaration.
    gradle_dependency,
};

/// Owned by Imports or Graph, with a byte offset at the construct's start.
// aegis: no danger there; docs/design.md: raw lexical positions describe one bounded source slice and undergo no unit conversion.
pub const UnsupportedReference = struct {
    /// Null for anonymous source bytes passed to `imports`.
    from: ?[]const u8 = null,
    offset: usize,
    expression: ImportExpression,
};

/// What recovery reads from one file; all slices borrow the source or the
/// arena that recovery was given.
pub const Recovery = struct {
    specs: []const Spec = &.{},
    unsupported: []const UnsupportedReference = &.{},
    /// The package a Java file declares, empty for none.
    package: []const u8 = "",

    /// Records and scopes belong to the workspace. Names and members belong to
    /// returned references, so copy them directly into graph storage once.
    pub fn clone(self: Recovery, arena: std.mem.Allocator, strings: std.mem.Allocator) std.mem.Allocator.Error!Recovery {
        const specs = try arena.dupe(Spec, self.specs);
        for (specs) |*spec| {
            spec.name = try strings.dupe(u8, spec.name);
            if (spec.member) |member| spec.member = try strings.dupe(u8, member);
            spec.scope = try arena.dupe(u8, spec.scope);
        }
        return .{ .specs = specs, .unsupported = try arena.dupe(UnsupportedReference, self.unsupported), .package = try arena.dupe(u8, self.package) };
    }
};

/// One lexical unit a token rule can name. Its text borrows the source, or
/// the arena when it is a decoded spelling; offsets are source bytes.
pub const Lexeme = struct {
    /// A template is an opaque string: a JS template boundary, or a whole
    /// string literal whose text is not a plain value (a Nim raw string with a
    /// prefix, which can be a formatting call, or a Groovy or Kotlin string
    /// that interpolates `$name` or `${code}`).
    kind: enum { word, string, template, punctuation, newline },
    text: []const u8,
    offset: usize,
    end: usize,
    pub fn is(t: Lexeme, s: []const u8) bool {
        return (t.kind == .word or t.kind == .punctuation) and std.mem.eql(u8, t.text, s);
    }
};

/// Called as each code unit or string joins a stream. `stream` ends with that
/// unit and holds the one before it too when there is one; an observer reads
/// no further back, so a frontend needs to keep no more. A frontend yields
/// exactly the units it recovers from: words (a keyword or a number is one),
/// strings, and punctuation, one byte of it at a time unless the language's
/// own operators are longer.
pub const Observer = struct {
    context: *anyopaque,
    /// Whether punctuation joins the calls.
    punctuation: bool = false,
    /// Called where a unit the stream omits (a character literal, a raw
    /// line) breaks any sequence of neighbours.
    boundary: ?*const fn (context: *anyopaque) void = null,
    token: *const fn (context: *anyopaque, stream: []const Lexeme) error{OutOfMemory}!void,
};

/// What a frontend's recovery fails with. The first three are about the
/// file's bytes and become records in `Graph.invalid`; memory is the scan's.
pub const RecoverError = error{ InvalidEscape, InvalidLiteral, SourceTooLarge, OutOfMemory };

/// A language read by a module of its own rather than by gantry's byte
/// lexers. It yields the file's imports, test contexts and liveness;
/// resolving them to files stays with the core.
pub const Frontend = struct {
    /// The language whose files this reads.
    language: Language,
    /// `arena` owns everything the result borrows. With `seen`, the units of
    /// the file reach the observer as they are read.
    recover: *const fn (arena: std.mem.Allocator, source: []const u8, seen: ?Observer) RecoverError!Recovery,
};

/// The frontend among `frontends` that reads `language`, if any.
pub fn find(frontends: []const Frontend, language: Language) ?Frontend {
    for (frontends) |candidate| if (candidate.language == language) return candidate;
    return null;
}
