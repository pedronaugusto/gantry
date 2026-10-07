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
    // The benchmarks are this repository's own, like its CI wiring.
    if (b.dep_prefix.len == 0) addBench(b, target, optimize, test_step);
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

/// `zig build bench` installs the benchmarks in ReleaseFast under
/// `zig-out/bench`; the test step compiles them in the requested mode and
/// runs none. `-Dbench-smoke` builds them to sample no clock.
fn addBench(b: *std.Build, target: std.Build.ResolvedTarget, optimize_tests: std.lang.Optimize, test_step: *std.Build.Step) void {
    const smoke = b.option(bool, "bench-smoke", "Benchmarks run once and sample no clock") orelse false;
    const bench = b.step("bench", "Install the benchmarks in ReleaseFast under zig-out/bench");
    const fixtures_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("bench/fixtures.zig"), .target = target }) });
    b.step("bench-test", "Run the benchmark fixture tests").dependOn(&b.addRunArtifact(fixtures_tests).step);
    for ([_]std.lang.Optimize{ .fast, optimize_tests }, 0..) |optimize, i| {
        const options = b.addOptions();
        options.addOption(bool, "smoke", smoke);
        const gantry = b.createModule(.{ .root_source_file = b.path("src/gantry.zig"), .target = target, .optimize = optimize });
        for ([_][2][]const u8{ .{ "scan", "bench/scan.zig" }, .{ "ops", "bench/ops.zig" }, .{ "fixtures", "bench/fixtures.zig" } }) |program| {
            const exe = b.addExecutable(.{ .name = program[0], .root_module = b.createModule(.{
                .root_source_file = b.path(program[1]),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "gantry", .module = gantry }},
            }) });
            exe.root_module.addOptions("bench_options", options);
            if (i == 0) {
                bench.dependOn(&b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = "bench" } } }).step);
            } else test_step.dependOn(&exe.step);
        }
    }
}
