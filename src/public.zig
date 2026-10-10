//! Dependency graphs, lexical recovery, analysis and architecture rules.
const graph_module = @import("gantry.graph");
const analysis_module = @import("gantry.analysis");
const scan_module = @import("gantry.scan");
const imports_module = @import("gantry.imports");
const rules_module = @import("gantry.rules");
const manifests_module = @import("gantry.manifests");
const path_module = @import("gantry.path");
const report_module = @import("gantry.report");
/// See `gantry.graph.Graph`.
pub const Graph = graph_module.Graph;
/// See `gantry.graph.Kind`.
pub const Kind = graph_module.Kind;
/// See `gantry.graph.Edge`.
pub const Edge = graph_module.Edge;
/// See `gantry.graph.ReferenceCount`.
pub const ReferenceCount = graph_module.ReferenceCount;
/// See `gantry.graph.ByteOffset`.
pub const ByteOffset = graph_module.ByteOffset;
/// See `gantry.graph.Reference`.
pub const Reference = graph_module.Reference;
/// See `gantry.graph.Token`.
pub const Token = graph_module.Token;
/// See `gantry.graph.UnsupportedReference`.
pub const UnsupportedReference = graph_module.UnsupportedReference;
/// See `gantry.graph.ImportExpression`.
pub const ImportExpression = graph_module.ImportExpression;
/// See `gantry.graph.Dependency`.
pub const Dependency = graph_module.Dependency;
/// See `gantry.graph.GoFile`.
pub const GoFile = graph_module.GoFile;
/// See `gantry.analysis.Analysis`.
pub const Analysis = analysis_module.Analysis;
/// See `gantry.analysis.Layer`.
pub const Layer = analysis_module.Layer;
/// See `gantry.analysis.Coupling`.
pub const Coupling = analysis_module.Coupling;
/// See `gantry.analysis.Cycle`.
pub const Cycle = analysis_module.Cycle;
/// See `gantry.scan.Options`.
pub const Options = scan_module.Options;
/// See `gantry.scan.scan`.
pub const scan = scan_module.scan;
/// See `gantry.scan.Frontend`.
pub const Frontend = scan_module.Frontend;
/// See `gantry.scan.kindsOf`.
pub const kindsOf = scan_module.kindsOf;
/// See `gantry.scan.Diagnostics`.
pub const Diagnostics = scan_module.Diagnostics;
/// See `gantry.scan.ScanError`.
pub const ScanError = scan_module.ScanError;
/// See `gantry.scan.ReadError`.
pub const ReadError = scan_module.ReadError;
/// See `gantry.scan.InvalidFile`.
pub const InvalidFile = scan_module.InvalidFile;
/// See `gantry.scan.FileError`.
pub const FileError = scan_module.FileError;
/// See `gantry.scan.DirReader`.
pub const DirReader = scan_module.DirReader;
/// See `gantry.scan.Paths`.
pub const Paths = scan_module.Paths;
/// See `gantry.scan.walk`.
pub const walk = scan_module.walk;
/// See `gantry.scan.WalkError`.
pub const WalkError = scan_module.WalkError;
/// See `gantry.scan.PythonInitializers`.
pub const PythonInitializers = scan_module.PythonInitializers;
/// See `gantry.scan.GoTarget`.
pub const GoTarget = scan_module.GoTarget;
/// See `gantry.scan.NamedModule`.
pub const NamedModule = scan_module.NamedModule;
/// See `gantry.imports.Language`.
pub const Language = imports_module.Language;
/// See `gantry.imports.Spec`.
pub const Spec = imports_module.Spec;
/// See `gantry.imports.Imports`.
pub const Imports = imports_module.Imports;
/// See `gantry.imports.imports`.
pub const imports = imports_module.imports;
/// See `gantry.imports.importsWith`.
pub const importsWith = imports_module.importsWith;
/// See `gantry.imports.ImportsError`.
pub const ImportsError = imports_module.ImportsError;
/// See `gantry.imports.languageOf`.
pub const languageOf = imports_module.languageOf;
/// Rules vocabulary.
pub const rules = rules_module;
/// Manifests vocabulary.
pub const manifests = manifests_module;
/// Path vocabulary.
pub const path = path_module;
/// Report vocabulary.
pub const report = report_module;
