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
pub const Graph = graph_module.Graph;
pub const Analysis = analysis_module.Analysis;
pub const Language = t.Language;
pub const Kind = t.Kind;
pub const Edge = t.Edge;
pub const Reference = t.Reference;
pub const Token = t.Token;
pub const UnsupportedReference = t.UnsupportedReference;
pub const ImportExpression = t.ImportExpression;
pub const Dependency = t.Dependency;
pub const Layer = t.Layer;
pub const Coupling = t.Coupling;
pub const Cycle = t.Cycle;
pub const Spec = t.Spec;
pub const PythonInitializers = resolver.PythonInitializers;
pub const GoTarget = build_module.Target;
pub const GoFile = build_module.File;
pub const NamedModule = resolver.NamedModule;
pub const rules = @import("rules.zig");
pub const manifests = @import("manifests.zig");
pub const path = @import("path.zig");
/// DOT, Mermaid, JSON and SARIF text for a graph and its findings.
pub const report = @import("report.zig");
pub const Options = options_module.Options;
pub const languageOf = options_module.languageOf;
/// The reference kinds a scan reads from a path, by its name alone.
pub const kindsOf = scan_module.kindsOf;
/// Raw lexical recovery, owning source bytes and every slice until deinit.
pub const Imports = scan_module.Imports;
pub const imports = scan_module.imports;
/// read(scratch_allocator, context, path) returns !?[]const u8. Bytes need
/// only survive processing until the next read. Null records an unread path;
/// an error aborts without a partial graph. Scratch is released per file.
/// The returned graph borrows neither input paths and options nor file bytes.
pub const scan = scan_module.scan;
/// The same atomic scan, with a caller-owned file, phase, optional byte offset
/// and cause on failure.
pub const scanWithDiagnostic = scan_module.scanWithDiagnostic;
pub const ScanDiagnostic = diagnostic_module.ScanDiagnostic;
/// Reader over an already-open directory; directory ownership stays with caller.
/// The byte limit is caller policy. A missing selected file is an I/O error.
pub const DirReader = struct {
    io: std.Io,
    dir: std.Io.Dir,
    limit: std.Io.Limit = .unlimited,
    pub fn read(a: std.mem.Allocator, self: DirReader, p: []const u8) !?[]const u8 {
        const value = try self.dir.readFileAlloc(self.io, p, a, self.limit);
        return value;
    }
};
/// Convenience listing. keep(context, slash_path, entry_kind) may prune a
/// directory; no ignore policy is imposed. Paths own their allocator.
pub const Paths = scan_module.Paths;
pub const walk = scan_module.walk;
