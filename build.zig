const std = @import("std");

pub fn build(b: *std.Build) void {
    importChecks(b);

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("gantry", .{ .root_source_file = b.path("src/gantry.zig"), .target = target, .optimize = optimize });
    const tests = b.addTest(.{
        .name = "gantry-tests",
        .filters = if (b.option([]const u8, "test-filter", "Select tests by name")) |filter| &.{filter} else &.{},
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            // Off so that `zig build test --fuzz` compiles: Zig 0.16.0's fuzz
            // runner hands `@errorReturnTrace()` to a function taking the other
            // `StackTrace` type. The failing input is the report there.
            .error_tracing = false,
        }),
    });
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

// Build-only tooling belongs to a root invocation, never a consumer's dependency graph.
fn importChecks(b: *std.Build) void {
    const step = b.step("check-imports", "Check source layers and import boundaries");
    if (b.pkg_hash.len != 0) return;
    const dependency = b.createModule(.{ .root_source_file = b.path("src/gantry.zig"), .target = b.graph.host, .optimize = .Debug });
    const checker = b.addExecutable(.{
        .name = "check-imports",
        .root_module = b.createModule(.{
            .root_source_file = b.path("ci/imports.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            .imports = &.{.{ .name = "gantry", .module = dependency }},
        }),
    });
    const run = b.addRunArtifact(checker);
    run.setCwd(b.path("."));
    if (b.args) |args| run.addArgs(args);
    step.dependOn(&run.step);
}
