const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("gantry", .{ .root_source_file = b.path("src/gantry.zig"), .target = target, .optimize = optimize });
    const tests = b.addTest(.{
        .name = "gantry-tests",
        .filters = if (b.option([]const u8, "test-filter", "Select tests by name")) |filter| &.{filter} else &.{},
        .root_module = b.createModule(.{ .root_source_file = b.path("src/gantry.zig"), .target = target, .optimize = optimize }),
    });
    const benchmark = b.addExecutable(.{
        .name = "scan",
        .root_module = b.createModule(.{ .root_source_file = b.path("bench/scan.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "gantry", .module = module }} }),
    });
    b.step("bench", "Build the benchmark (run with python3 bench/run.py)").dependOn(&b.addInstallArtifact(benchmark, .{}).step);
    const test_step = b.step("test", "Run the tests and example");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    b.step("check", "Compile the tests without running them").dependOn(&tests.step);
    const example = b.addExecutable(.{
        .name = "usage",
        .root_module = b.createModule(.{ .root_source_file = b.path("examples/usage.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "gantry", .module = module }} }),
    });
    const run = b.addRunArtifact(example);
    const examples = b.step("examples", "Build and run the usage example");
    examples.dependOn(&run.step);
    test_step.dependOn(examples);
    b.installArtifact(b.addLibrary(.{ .name = "gantry", .root_module = module }));
    b.getInstallStep().dependOn(&tests.step);
    b.getInstallStep().dependOn(&example.step);
}
