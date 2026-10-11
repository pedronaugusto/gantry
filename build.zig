const std = @import("std");

/// What a project that depends on gantry builds: the `gantry` module, its library,
/// and with `-Dzig` the `gantry.zig` frontend, which fetches glint. The tests,
/// example, checks and gate are `dev`'s.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const aegis = b.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis");
    // Path rules use sweep; semantic scalar domains use aegis.
    const sweep = b.dependency("sweep", .{ .target = target, .optimize = optimize }).module("sweep");
    const root = b.addModule("gantry", .{ .root_source_file = b.path("src/gantry.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "sweep", .module = sweep }, .{ .name = "aegis", .module = aegis } } });
    b.installArtifact(b.addLibrary(.{ .name = "gantry", .root_module = root }));
    // Zig is read by a frontend module on glint's token tier. A project that
    // never analyses Zig builds without it and fetches nothing for it.
    if (b.option(bool, "zig", "Build the gantry.zig frontend, which fetches glint") orelse false) {
        // The module is declared either way, so a consumer can ask for it while glint is fetched.
        // On the first pass Zig fetches glint and configures again.
        const zig = b.addModule("gantry.zig", .{ .root_source_file = b.path("src/frontends/zig.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "gantry", .module = root }} });
        if (b.dependencyLazy("glint", .{ .target = target, .optimize = optimize })) |glint| zig.addImport("glint", glint.module("glint")) else |_| {}
    }
}

/// gantry's development: its tests, example, checks and benchmarks under
/// preflight's gate, with shakedown bound to gantry's aegis. Run through bay.
pub fn dev(b: *std.Build, tools: type) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Select tests by name");
    const package = b.dependency("gantry", .{ .target = target, .optimize = optimize, .zig = true });
    const p = package.builder;
    const module = package.module("gantry");
    const zig_module = package.module("gantry.zig");
    const library = package.artifact("gantry");
    const aegis_package = p.dependency("aegis", .{ .target = target, .optimize = optimize });
    const aegis = aegis_package.module("aegis");
    const sweep_package = p.dependency("sweep", .{ .target = target, .optimize = optimize });
    const filters = if (test_filter) |filter| &.{filter} else &.{};
    // The tests are the core module's own, so they reach its files. The Zig frontend they scan
    // with imports the core, so the core imports it back here and nowhere else.
    module.addImport("zig_frontend", zig_module);
    // The schema the SARIF goldens are held to, which the tests embed.
    module.addAnonymousImport("sarif_schema", .{ .root_source_file = p.path("ci/sarif-schema-2.1.0.json") });
    const tests = b.addTest(.{ .name = "gantry-tests", .filters = filters, .root_module = module });
    const domains = b.step("check-domains", "Reject raw counts and mixed diagnostic domains");
    for ([_][]const u8{ "raw_count", "mixed_offset" }) |name| {
        const negative = b.addObject(.{ .name = name, .root_module = b.createModule(.{ .root_source_file = p.path(b.fmt("ci/domains/{s}.zig", .{name})), .target = target, .optimize = optimize, .imports = &.{.{ .name = "gantry", .module = module }} }) });
        negative.expect_errors = .{ .contains = if (std.mem.eql(u8, name, "raw_count")) "error: expected type 'units.Count(types.ReferenceCountTag,usize)', found 'usize'" else "error: expected type '?id.Identity(types.ByteOffsetTag,usize,false)', found 'units.Count(types.ReferenceCountTag,usize)'" };
        domains.dependOn(&negative.step);
    }
    const test_step = b.step("test", "Run the tests and example");
    test_step.dependOn(domains);
    test_step.dependOn(&b.addRunArtifact(tests).step);
    // The benchmarks' inputs keep their bytes, so a change to them is seen
    // before it moves a measurement.
    const fixtures = b.addTest(.{ .name = "bench-fixtures", .filters = filters, .root_module = b.createModule(.{ .root_source_file = p.path("bench/fixtures.zig"), .target = target, .optimize = optimize }) });
    test_step.dependOn(&b.addRunArtifact(fixtures).step);
    const check = b.step("check", "Compile the tests, library and example without running them");
    check.dependOn(&tests.step);
    check.dependOn(&fixtures.step);
    check.dependOn(&library.step);
    const example = b.addExecutable(.{
        .name = "usage",
        .root_module = b.createModule(.{ .root_source_file = p.path("examples/usage.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "gantry", .module = module }, .{ .name = "gantry.zig", .module = zig_module } } }),
    });
    const examples = b.step("examples", "Build and run the usage example");
    examples.dependOn(&b.addRunArtifact(example).step);
    test_step.dependOn(examples);
    check.dependOn(&example.step);
    b.getInstallStep().dependOn(&tests.step);
    b.getInstallStep().dependOn(&example.step);
    // The test doubles are shakedown's, bound to gantry's aegis so one aegis is linked.
    const shakedown_package = b.dependency("shakedown", .{ .target = target, .optimize = optimize, .aegis = .consumer });
    tools.shakedown.useAegis(shakedown_package, aegis);
    const shakedown = shakedown_package.module("shakedown");
    module.addImport("shakedown", shakedown);
    fixtures.root_module.addImport("shakedown", shakedown);
    tools.preflight.addCi(b, p, .{
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
    // A project that depends on gantry by path, with no packages to
    // fetch: the build a consumer gets.
    tools.preflight.addConsumerCheck(b, p, .{ .package = "gantry", .program = p.path("ci/consumer.zig"), .modules = &.{"gantry"}, .packages = &.{ sweep_package, aegis_package } });
}

/// gantry, its Zig frontend and shakedown in the mode a benchmark builds in:
/// an imported module keeps its own mode, so a ReleaseFast benchmark over the
/// Debug module would time the Debug module. `b` is the development build.
fn benchImports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) []const std.Build.Module.Import {
    const p = b.dependency("gantry", .{ .target = target, .optimize = optimize, .zig = true }).builder;
    const sweep = p.dependency("sweep", .{ .target = target, .optimize = optimize }).module("sweep");
    const aegis = p.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis");
    const glint = p.dependency("glint", .{ .target = target, .optimize = optimize }).module("glint");
    const root = b.createModule(.{ .root_source_file = p.path("src/gantry.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "sweep", .module = sweep }, .{ .name = "aegis", .module = aegis } } });
    const zig = b.createModule(.{ .root_source_file = p.path("src/frontends/zig.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "gantry", .module = root }, .{ .name = "glint", .module = glint } } });
    // The same binding as `useAegis`, which only a `dev` has the tools for: one aegis is linked.
    const shakedown_package = b.dependency("shakedown", .{ .target = target, .optimize = optimize, .aegis = .consumer });
    shakedown_package.module("shakedown").addImport("aegis", aegis);
    return b.allocator.dupe(std.Build.Module.Import, &.{
        .{ .name = "gantry", .module = root },
        .{ .name = "gantry.zig", .module = zig },
        .{ .name = "shakedown", .module = shakedown_package.module("shakedown") },
    }) catch @panic("OOM");
}
