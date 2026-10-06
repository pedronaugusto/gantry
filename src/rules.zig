//! Public rule data and checking over an owned graph.
const graph_module = @import("graph.zig");
const engine = @import("rules/check.zig");
const std = @import("std");
const Graph = graph_module.Graph;
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
pub const Findings = engine.Findings;
pub const CheckError = engine.CheckError;
pub const matches = engine.matches;
pub const matchesToken = engine.matchesToken;

pub fn check(a: std.mem.Allocator, g: *const Graph, rules: Rules) CheckError!Findings {
    return g.check(a, rules);
}
