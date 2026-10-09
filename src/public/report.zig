//! Report vocabulary; the package owns each declaration once.
const concern = @import("implementation").report;
/// See `gantry.report.Error`.
pub const Error = concern.Error;
/// See `gantry.report.json`.
pub const json = concern.json;
/// See `gantry.report.sarif`.
pub const sarif = concern.sarif;
/// See `gantry.report.SourceError`.
pub const SourceError = concern.SourceError;
/// See `gantry.report.SarifOptions`.
pub const SarifOptions = concern.SarifOptions;
/// See `gantry.report.Cluster`.
pub const Cluster = concern.Cluster;
/// See `gantry.report.Options`.
pub const Options = concern.Options;
/// See `gantry.report.dot`.
pub const dot = concern.dot;
/// See `gantry.report.mermaid`.
pub const mermaid = concern.mermaid;
