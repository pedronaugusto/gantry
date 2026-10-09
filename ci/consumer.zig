//! Build all public concerns together, with no CI dependencies fetched.
const std = @import("std");
const gantry = @import("gantry");
const graph = @import("gantry.graph");
const analysis = @import("gantry.analysis");
const scan = @import("gantry.scan");
const imports = @import("gantry.imports");
const rules = @import("gantry.rules");
const manifests = @import("gantry.manifests");
const path = @import("gantry.path");
const report = @import("gantry.report");

pub fn main() void {
    comptime {
        std.debug.assert(@sizeOf(gantry.ReferenceCount) == @sizeOf(usize));
        std.debug.assert(@sizeOf(gantry.ByteOffset) == @sizeOf(usize));
        std.debug.assert(gantry.ReferenceCount != gantry.ByteOffset);
        std.debug.assert(gantry.Graph == graph.Graph);
        std.debug.assert(gantry.Analysis == analysis.Analysis);
        std.debug.assert(gantry.Options == scan.Options);
        std.debug.assert(gantry.Imports == imports.Imports);
        std.debug.assert(gantry.rules.Rules == rules.Rules);
        std.debug.assert(gantry.manifests.Declarations == manifests.Declarations);
        std.debug.assert(gantry.report.Options == report.Options);
    }
    _ = &gantry.scan;
    _ = &graph.Graph.check;
    _ = &path.normalize;
}
