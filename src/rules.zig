//! Public rule data and checking over an owned graph.
const engine = @import("rules/check.zig");
/// A named set of path patterns in an ordered layer rule.
pub const Layer = engine.Layer;
/// Layers lowest first: a file may import its own layer or lower ones.
pub const OrderedLayers = engine.OrderedLayers;
/// A restriction on edges from one pattern to another, direct or transitive.
pub const EdgeRule = engine.EdgeRule;
/// An exception to a named restriction.
pub const Allow = engine.Allow;
/// A restriction on raw references, resolved or not.
pub const ReferenceRule = engine.ReferenceRule;
/// Paths that must be in the graph.
pub const Required = engine.Required;
/// Files every one of which some chain from an entry must reach.
pub const Reachable = engine.Reachable;
/// Imports checked against the manifests that govern their files.
pub const DependencyRule = engine.DependencyRule;
/// Identifiers or string values only the owners' files may spell.
pub const TokenRule = engine.TokenRule;
/// Every restriction `Graph.check` applies, in rule order.
pub const Rules = engine.Rules;
/// One finding: its rule, reason and what it is about.
pub const Violation = engine.Violation;
/// The owned findings of one check.
pub const Findings = engine.Findings;
/// What `Graph.check` fails with.
pub const CheckError = engine.CheckError;
/// Whether a path pattern matches a path.
pub const matches = engine.matches;
/// Whether a token pattern matches a token's text.
pub const matchesToken = engine.matchesToken;
