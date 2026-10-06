const std = @import("std");

pub fn build(b: *std.Build) void {
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
    const check = b.step("check", "Compile the tests, library and example without running them");
    check.dependOn(&tests.step);
    const example = b.addExecutable(.{
        .name = "usage",
        .root_module = b.createModule(.{ .root_source_file = b.path("examples/usage.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "gantry", .module = module }} }),
    });
    const run = b.addRunArtifact(example);
    const examples = b.step("examples", "Build and run the usage example");
    examples.dependOn(&run.step);
    test_step.dependOn(examples);
    const library = b.addLibrary(.{ .name = "gantry", .root_module = module });
    b.installArtifact(library);
    check.dependOn(&library.step);
    check.dependOn(&example.step);
    // CI wiring is this repository's own. preflight is lazy and only the
    // root build asks for it, so a project depending on gantry neither
    // needs nor fetches it.
    if (b.dep_prefix.len == 0) if (b.lazyImport(@This(), "preflight")) |preflight| {
        preflight.addCi(b, .{ .tests = test_step, .portable_tests = true });
        // A project that depends on gantry by path, with no packages to
        // fetch: the build a consumer gets.
        preflight.addConsumerCheck(b, .{ .package = "gantry", .program = b.path("ci/consumer.zig") });
        // Validates the report goldens with their downstream tools.
        check.dependOn(&preflight.addCheck(b, "check-reports", "ci/reports.zig").step);
    };
    b.getInstallStep().dependOn(&tests.step);
    b.getInstallStep().dependOn(&example.step);
}
