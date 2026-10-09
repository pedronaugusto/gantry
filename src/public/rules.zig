//! Rules vocabulary; the package owns each declaration once.
const concern = @import("implementation").rules;
/// See `gantry.rules.Layer`.
pub const Layer = concern.Layer;
/// See `gantry.rules.OrderedLayers`.
pub const OrderedLayers = concern.OrderedLayers;
/// See `gantry.rules.EdgeRule`.
pub const EdgeRule = concern.EdgeRule;
/// See `gantry.rules.Allow`.
pub const Allow = concern.Allow;
/// See `gantry.rules.ReferenceRule`.
pub const ReferenceRule = concern.ReferenceRule;
/// See `gantry.rules.Required`.
pub const Required = concern.Required;
/// See `gantry.rules.Reachable`.
pub const Reachable = concern.Reachable;
/// See `gantry.rules.DependencyRule`.
pub const DependencyRule = concern.DependencyRule;
/// See `gantry.rules.TokenRule`.
pub const TokenRule = concern.TokenRule;
/// See `gantry.rules.Rules`.
pub const Rules = concern.Rules;
/// See `gantry.rules.Violation`.
pub const Violation = concern.Violation;
/// See `gantry.rules.Findings`.
pub const Findings = concern.Findings;
/// See `gantry.rules.CheckError`.
pub const CheckError = concern.CheckError;
/// See `gantry.rules.matches`.
pub const matches = concern.matches;
/// See `gantry.rules.matchesToken`.
pub const matchesToken = concern.matchesToken;
/// See `gantry.rules.Dialect`.
pub const Dialect = concern.Dialect;
/// See `gantry.rules.Globs`.
pub const Globs = concern.Globs;
/// See `gantry.rules.Pattern`.
pub const Pattern = concern.Pattern;
/// See `gantry.rules.CompileError`.
pub const CompileError = concern.CompileError;
/// See `gantry.rules.anyOf`.
pub const anyOf = concern.anyOf;
/// See `gantry.rules.literal`.
pub const literal = concern.literal;
