//! gantry reads caller-selected files and records their dependencies.
//! Managed results own their allocator; slices belong to that result until
//! deinit. There is no global state, git, compiler invocation or thread.
const graph_module = @import("graph.zig");
const analysis_module = @import("analysis.zig");
const build_module = @import("lang/go/build.zig");
const options_module = @import("scan/options.zig");
const scan_module = @import("scan.zig");
const diagnostic_module = @import("scan/diagnostic.zig");
const std = @import("std");
const t = @import("types.zig");
const resolver = @import("resolve.zig");
/// A scan's or `fromEdges`'s owned graph: files, edges, references and records.
pub const Graph = graph_module.Graph;
/// Layers, components, cycle witnesses, coupling and queries over a graph.
pub const Analysis = analysis_module.Analysis;
/// The source languages import recovery reads.
pub const Language = t.Language;
/// What an edge or reference is: `import`, `type_only`, `dynamic`, `test`, `link` or `asset`.
pub const Kind = t.Kind;
/// A dependency between two files, with its kind and reference count.
pub const Edge = t.Edge;
/// Reference occurrences, with checked addition and explicit raw extraction.
pub const ReferenceCount = t.ReferenceCount;
/// A diagnostic byte position, explicitly imported from or extracted to usize.
pub const ByteOffset = t.ByteOffset;
/// One recovered import spelling, its offset, kind and resolution status.
pub const Reference = t.Reference;
/// An identifier or string literal that a token rule names.
pub const Token = t.Token;
/// An import or manifest construct that recovery detects but cannot read.
pub const UnsupportedReference = t.UnsupportedReference;
/// The construct an `UnsupportedReference` is.
pub const ImportExpression = t.ImportExpression;
/// One dependency a manifest declares.
pub const Dependency = t.Dependency;
/// A file and its depth in an analysis.
pub const Layer = t.Layer;
/// A node's or directory's dependents and dependencies.
pub const Coupling = t.Coupling;
/// A strongly connected component and one closed witness path through it.
pub const Cycle = t.Cycle;
/// A raw recovered reference from `imports`.
pub const Spec = t.Spec;
/// Which Python package initializers an import reaches.
pub const PythonInitializers = resolver.PythonInitializers;
/// The Go operating system, architecture and tags that select build constraints.
pub const GoTarget = build_module.Target;
/// A Go file's package, constraint and whether `Options.go_target` selects it.
pub const GoFile = build_module.File;
/// A Zig module name that resolves to a selected file.
pub const NamedModule = resolver.NamedModule;
/// Rule data and checking over a graph.
pub const rules = @import("rules.zig");
/// Dependency declarations read from manifests.
pub const manifests = @import("manifests.zig");
/// The slash-separated relative paths every graph uses.
pub const path = @import("path.zig");
/// DOT, Mermaid, JSON and SARIF text for a graph and its findings.
pub const report = @import("report.zig");
/// What `scan` records, resolves and checks, and where it reports a failure.
pub const Options = options_module.Options;
/// The language a path is read as, by its extension.
pub const languageOf = options_module.languageOf;
/// The reference kinds a scan reads from a path, by its name alone.
pub const kindsOf = scan_module.kindsOf;
/// Raw lexical recovery, owning source bytes and every slice until deinit.
pub const Imports = scan_module.Imports;
/// Lexical recovery from one anonymous source buffer.
pub const imports = scan_module.imports;
/// What `imports` fails with.
pub const ImportsError = scan_module.ImportsError;
/// read(scratch, io, context, path) returns `E!?[]const u8`. Bytes need
/// only survive processing until the next read. Null records an unread path;
/// a reader error aborts without a partial graph, as a `ScanError` does. A
/// file whose bytes are not valid for its format is a record in
/// `Graph.invalid`, not an error. Scratch is released per file.
/// `Options.diagnostics` keeps the failed file, phase, optional byte offset
/// and cause. The returned graph borrows neither input paths and options
/// nor file bytes.
pub const scan = scan_module.scan;
/// Caller-owned output for a failed scan, through `Options.diagnostics`.
pub const Diagnostics = diagnostic_module.Diagnostics;
/// What `scan` fails with besides the reader's errors.
pub const ScanError = diagnostic_module.ScanError;
/// The errors a reader function returns; `scan` returns these and `ScanError`.
pub const ReadError = diagnostic_module.ReadError;
/// A selected file the scan read but could not use, in `Graph.invalid`.
pub const InvalidFile = diagnostic_module.InvalidFile;
/// Why a file is invalid: a scan records it, a single-file reader returns it.
pub const FileError = diagnostic_module.FileError;
/// Reader over an already-open directory; directory ownership stays with caller.
/// The byte limit is caller policy. A missing selected file is an I/O error.
// aegis: C or OS boundary; docs/design.md: the std Io reader limit is passed unchanged to the directory read call.
pub const DirReader = struct {
    dir: std.Io.Dir,
    limit: std.Io.Limit = .unlimited,
    pub const ReadError = std.Io.Dir.ReadFileAllocError;
    pub fn read(self: DirReader, scratch: std.mem.Allocator, io: std.Io, p: []const u8) DirReader.ReadError!?[]const u8 {
        const value = try self.dir.readFileAlloc(io, p, scratch, self.limit);
        return value;
    }
};
/// Convenience listing. keep(context, slash_path, entry_kind) may prune a
/// directory; no ignore policy is imposed. A name `path.normalize` refuses
/// (a backslash, a `C:` drive spelling at the root) is skipped, so every
/// listed path can be scanned. Paths own their allocator.
pub const Paths = scan_module.Paths;
/// Lists the files under a directory, sorted, as `Paths`.
pub const walk = scan_module.walk;
/// What `walk` fails with.
pub const WalkError = scan_module.WalkError;
