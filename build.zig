const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const aegis_package = b.dependency("aegis", .{ .target = target, .optimize = optimize });
    const aegis = aegis_package.module("aegis");
    // Path rules use sweep; semantic scalar domains use aegis.
    const sweep_package = b.dependency("sweep", .{ .target = target, .optimize = optimize });
    const sweep = sweep_package.module("sweep");
    // Zig is read by a frontend module on glint's token tier. A project that
    // never analyses Zig builds without it and fetches nothing for it; this
    // repository's own build always has it.
    const own_tree = b.pkg_hash.len == 0;
    const with_zig = own_tree or (b.option(bool, "zig", "Build the gantry.zig frontend, which fetches glint") orelse false);
    const glint = if (with_zig) (try b.dependencyLazy("glint", .{ .target = target, .optimize = optimize })).module("glint") else null;
    const modules = publicModules(b, target, optimize, sweep, aegis, glint, true);
    const module = modules.root;
    const library = b.addLibrary(.{ .name = "gantry", .root_module = module });
    b.installArtifact(library);
    // Everything below is this repository's own: a project depending on
    // gantry builds the module and nothing else, and fetches nothing for it.
    if (!own_tree) return;
    const filters = if (b.option([]const u8, "test-filter", "Select tests by name")) |filter| &.{filter} else &.{};
    // The tests are the core module's own, so they reach its files. The Zig frontend they scan
    // with imports the core, so the core imports it back here and nowhere else.
    module.addImport("zig_frontend", modules.zig.?);
    const tests = b.addTest(.{ .name = "gantry-tests", .filters = filters, .root_module = module });
    const domains = b.step("check-domains", "Reject raw counts and mixed diagnostic domains");
    for ([_][]const u8{ "raw_count", "mixed_offset" }) |name| {
        const negative = b.addObject(.{ .name = name, .root_module = b.createModule(.{ .root_source_file = b.path(b.fmt("ci/domains/{s}.zig", .{name})), .target = target, .optimize = optimize, .imports = &.{.{ .name = "gantry", .module = module }} }) });
        negative.expect_errors = .{ .contains = if (std.mem.eql(u8, name, "raw_count")) "error: expected type 'units.Count(types.ReferenceCountTag,usize)', found 'usize'" else "error: expected type '?id.Identity(types.ByteOffsetTag,usize,false)', found 'units.Count(types.ReferenceCountTag,usize)'" };
        domains.dependOn(&negative.step);
    }
    const test_step = b.step("test", "Run the tests and example");
    test_step.dependOn(domains);
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
        .root_module = b.createModule(.{ .root_source_file = b.path("examples/usage.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "gantry", .module = module }, .{ .name = "gantry.zig", .module = modules.zig.? } } }),
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
    module.addImport("shakedown", shakedown);
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
        // A project that depends on gantry by path, with no packages to
        // fetch: the build a consumer gets.
        preflight.addConsumerCheck(b, .{ .package = "gantry", .program = b.path("ci/consumer.zig"), .modules = &.{"gantry"}, .packages = &.{ sweep_package, aegis_package } });
        // Validates the report goldens with their downstream tools.
        check.dependOn(&preflight.addCheck(b, "check-reports", "ci/reports.zig").step);
        // Those tools on the Ubuntu runner, which has node: the report job's setup.
        const update = b.addSystemCommand(&.{ "sudo", "apt-get", "update", "-q" });
        const install = b.addSystemCommand(&.{ "sudo", "apt-get", "install", "-y", "-q", "graphviz", "python3-jsonschema" });
        install.step.dependOn(&update.step);
        b.step("reports-setup", "Install the tools check-reports runs, on an Ubuntu runner").dependOn(&install.step);
    }
}

/// gantry, its Zig frontend and shakedown in the mode a benchmark builds in:
/// an imported module keeps its own mode, so a ReleaseFast benchmark over the
/// Debug module would time the Debug module.
fn benchImports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) []const std.Build.Module.Import {
    const sweep = b.dependency("sweep", .{ .target = target, .optimize = optimize }).module("sweep");
    const aegis = b.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis");
    // unreachable: `build` returns before `addCi` while glint is missing.
    const glint = (b.dependencyLazy("glint", .{ .target = target, .optimize = optimize }) catch unreachable).module("glint");
    const gantry = publicModules(b, target, optimize, sweep, aegis, glint, false);
    // unreachable: `build` returns before `addCi` while shakedown is missing.
    const shakedown = (b.dependencyLazy("shakedown", .{ .target = target, .optimize = optimize }) catch unreachable).module("shakedown");
    return b.allocator.dupe(std.Build.Module.Import, &.{
        .{ .name = "gantry", .module = gantry.root },
        .{ .name = "gantry.zig", .module = gantry.zig.? },
        .{ .name = "shakedown", .module = shakedown },
    }) catch @panic("OOM");
}

const Modules = struct {
    /// `gantry`: every concern, as namespaces of one module.
    root: *std.Build.Module,
    /// `gantry.zig`, when glint is there to build it on.
    zig: ?*std.Build.Module,
};

/// The core is one module. Its concerns are namespaces of it, since none has a dependency of
/// its own that a user should not fetch. The Zig frontend is a module apart because it needs
/// glint; it imports the core for the frontend vocabulary and the core imports nothing of it.
fn publicModules(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, sweep: *std.Build.Module, aegis: *std.Build.Module, glint: ?*std.Build.Module, publish: bool) Modules {
    const root = b.createModule(.{ .root_source_file = b.path("src/gantry.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "sweep", .module = sweep }, .{ .name = "aegis", .module = aegis } } });
    const zig = if (glint) |dependency| b.createModule(.{ .root_source_file = b.path("src/frontends/zig.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "gantry", .module = root }, .{ .name = "glint", .module = dependency } } }) else null;
    if (publish) {
        b.modules.put(b.allocator, "gantry", root) catch @panic("OOM");
        if (zig) |module| b.modules.put(b.allocator, "gantry.zig", module) catch @panic("OOM");
    }
    return .{ .root = root, .zig = zig };
}
