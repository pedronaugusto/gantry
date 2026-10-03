const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const options = b.addOptions();
    options.addOption(bool, "smoke", b.option(bool, "smoke", "Tiny correctness pass") orelse false);
    const package = b.dependency(if (b.option(bool, "snapshot", "Build the archived local revision") orelse false) "gantry" else "after", .{ .target = target, .optimize = optimize });
    inline for (.{ .{ "scan", "scan.zig" }, .{ "compare-scan", "compare/scan.zig" }, .{ "ops", "ops.zig" } }) |spec| {
        const exe = b.addExecutable(.{ .name = spec[0], .root_module = b.createModule(.{
            .root_source_file = b.path(spec[1]),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "gantry", .module = package.module("gantry") }},
        }) });
        exe.root_module.addOptions("bench_options", options);
        b.installArtifact(exe);
    }
    // Zig's own parser as the comparison for Zig imports and ZON manifests.
    b.installArtifact(b.addExecutable(.{ .name = "alt-zig", .root_module = b.createModule(.{
        .root_source_file = b.path("alt/alt.zig"),
        .target = target,
        .optimize = optimize,
    }) }));
}
