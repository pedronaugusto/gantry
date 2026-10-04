//! Public rule data and checking over an owned graph.
const engine = @import("rules/check.zig");
const std = @import("std");
const Graph = @import("Graph.zig").Graph;
pub const Layer = engine.Layer;
pub const OrderedLayers = engine.OrderedLayers;
pub const EdgeRule = engine.EdgeRule;
pub const Allow = engine.Allow;
pub const ReferenceRule = engine.ReferenceRule;
pub const Required = engine.Required;
pub const Reachable = engine.Reachable;
pub const DependencyRule = engine.DependencyRule;
pub const TokenRule = engine.TokenRule;
pub const Rules = engine.Rules;
pub const Violation = engine.Violation;
pub const matches = engine.matches;
pub const matchesToken = engine.matchesToken;
/// Frees `check`'s findings with the chains of transitive ones.
pub const free = engine.free;

pub fn check(g: *const Graph, a: std.mem.Allocator, rules: Rules) ![]const Violation {
    return g.check(a, rules);
}
