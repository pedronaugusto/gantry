const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // gantry's only dependency: the glob engine its path rules read.
    const sweep_package = b.dependency("sweep", .{ .target = target, .optimize = optimize });
    const sweep = sweep_package.module("sweep");
    const module = b.addModule("gantry", .{ .root_source_file = b.path("src/gantry.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "sweep", .module = sweep }} });
    const library = b.addLibrary(.{ .name = "gantry", .root_module = module });
    b.installArtifact(library);
    // Everything below is this repository's own: a project depending on
    // gantry builds the module and nothing else, and fetches nothing for it.
    if (b.pkg_hash.len != 0) return;
    const filters = if (b.option([]const u8, "test-filter", "Select tests by name")) |filter| &.{filter} else &.{};
    const tests = b.addTest(.{
        .name = "gantry-tests",
        .filters = filters,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "sweep", .module = sweep }},
        }),
    });
    const test_step = b.step("test", "Run the tests and example");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    // The benchmarks' inputs keep their bytes, so a change to them is seen
    // before it moves a measurement.
    const fixtures = b.addTest(.{ .name = "bench-fixtures", .filters = filters, .root_module = b.createModule(.{ .root_source_file = b.path("bench/fixtures.zig"), .target = target, .optimize = optimize }) });
    test_step.dependOn(&b.addRunArtifact(fixtures).step);
    const check = b.step("check", "Compile the tests, library and example without running them");
    check.dependOn(&tests.step);
    check.dependOn(&fixtures.step);
    check.dependOn(&library.step);
    const example = b.addExecutable(.{
        .name = "usage",
        .root_module = b.createModule(.{ .root_source_file = b.path("examples/usage.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "gantry", .module = module }} }),
    });
    const examples = b.step("examples", "Build and run the usage example");
    examples.dependOn(&b.addRunArtifact(example).step);
    test_step.dependOn(examples);
    check.dependOn(&example.step);
    b.getInstallStep().dependOn(&tests.step);
    b.getInstallStep().dependOn(&example.step);
    // CI wiring, and the test doubles: preflight and shakedown are lazy and
    // only the root build asks for them, both in one configure pass.
    const ci = b.lazyImport(@This(), "preflight");
    const shakedown = (try b.dependencyLazy("shakedown", .{ .target = target, .optimize = optimize })).module("shakedown");
    tests.root_module.addImport("shakedown", shakedown);
    fixtures.root_module.addImport("shakedown", shakedown);
    if (ci) |preflight| {
        preflight.addCi(b, .{
            .tests = test_step,
            .portable_tests = true,
            .bench = .{
                .programs = &.{
                    .{ .name = "scan", .source = "bench/scan.zig" },
                    .{ .name = "ops", .source = "bench/ops.zig" },
                    // Writes the fixtures trials reads; times nothing.
                    .{ .name = "fixtures", .source = "bench/fixtures.zig", .timed = false },
                },
                .imports = benchImports,
                .target = target,
                .optimize = optimize,
            },
        });
        // The hosted matrices come from preflight's planner, with the same
        // repository configuration as the source gate.
        const tooling = try b.dependencyLazy("preflight", .{});
        const tool_target = b.resolveTargetQuery(.{ .cpu_arch = b.graph.host.result.cpu.arch, .cpu_model = .baseline, .os_tag = b.graph.host.result.os.tag, .abi = b.graph.host.result.abi });
        const tool_gantry = try tooling.builder.dependencyLazy("gantry", .{ .target = tool_target, .optimize = .debug });
        const planner = b.addExecutable(.{
            .name = "preflight-checks",
            .root_module = b.createModule(.{ .root_source_file = tooling.path("src/main.zig"), .target = tool_target, .optimize = .safe, .imports = &.{.{ .name = "gantry", .module = tool_gantry.module("gantry") }} }),
        });
        const plan = b.addRunArtifact(planner);
        plan.setCwd(b.path("."));
        plan.addArgs(&.{ "plan", "--config", "ci/workflow.json" });
        plan.addPassthruArgs();
        b.step("plan", "Print the hosted CI plan from preflight").dependOn(&plan.step);
        // A project that depends on gantry by path, with no packages to
        // fetch: the build a consumer gets.
        preflight.addConsumerCheck(b, .{ .package = "gantry", .program = b.path("ci/consumer.zig"), .packages = &.{sweep_package} });
        // Validates the report goldens with their downstream tools.
        check.dependOn(&preflight.addCheck(b, "check-reports", "ci/reports.zig").step);
    }
}

/// gantry and shakedown in the mode a benchmark builds in: an imported
/// module keeps its own mode, so a ReleaseFast benchmark over the Debug
/// module would time the Debug module.
fn benchImports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) []const std.Build.Module.Import {
    const sweep = b.dependency("sweep", .{ .target = target, .optimize = optimize }).module("sweep");
    const gantry = b.createModule(.{ .root_source_file = b.path("src/gantry.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "sweep", .module = sweep }} });
    // unreachable: `build` returns before `addCi` while shakedown is missing.
    const shakedown = (b.dependencyLazy("shakedown", .{ .target = target, .optimize = optimize }) catch unreachable).module("shakedown");
    return b.allocator.dupe(std.Build.Module.Import, &.{
        .{ .name = "gantry", .module = gantry },
        .{ .name = "shakedown", .module = shakedown },
    }) catch @panic("OOM");
}
