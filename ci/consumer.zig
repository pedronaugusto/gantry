//! Build the package as a consumer gets it, with no CI dependencies fetched.
const std = @import("std");
const gantry = @import("gantry");

pub fn main() void {
    comptime {
        std.debug.assert(@sizeOf(gantry.ReferenceCount) == @sizeOf(usize));
        std.debug.assert(@sizeOf(gantry.ByteOffset) == @sizeOf(usize));
        std.debug.assert(gantry.ReferenceCount != gantry.ByteOffset);
        std.debug.assert(gantry.Frontend == gantry.frontend.Frontend);
    }
    _ = &gantry.scan;
    _ = &gantry.Graph.check;
    _ = &gantry.rules.Rules;
    _ = &gantry.manifests.parse;
    _ = &gantry.report.Options;
    _ = &gantry.path.normalize;
}
