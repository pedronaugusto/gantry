//! What a project that depends on gantry and nothing else writes. Built by
//! `zig build check-consumer` with no packages to fetch, so gantry's
//! build.zig must work without any of its own CI dependencies.
const gantry = @import("gantry");

pub fn main() void {
    _ = &gantry.scan;
    _ = &gantry.Graph.check;
}
