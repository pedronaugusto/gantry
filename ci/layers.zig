//! Source layers, lowest first. Every source has one explicit place.
const gantry = @import("gantry");

pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "primitives", .patterns = &.{
        "src/jsonc.zig",
        "src/owned_slice.zig",
        "src/path.zig",
        "src/scan_diagnostic.zig",
        "src/types.zig",
    } },
    .{ .name = "storage and matching", .patterns = &.{
        "src/analysis_store.zig",
        "src/import_store.zig",
        "src/lexer.zig",
        "src/reach.zig",
        "src/resolve_path.zig",
        "src/rules_check.zig",
        "src/scan_reader.zig",
    } },
    .{ .name = "recovery and configuration", .patterns = &.{
        "src/Imports.zig",
        "src/go_build.zig",
        "src/go_config.zig",
        "src/gradle.zig",
        "src/lang/c.zig",
        "src/lang/java.zig",
        "src/lang/nim.zig",
        "src/lang/python.zig",
        "src/lang/rust.zig",
        "src/lang/zig.zig",
        "src/manifests.zig",
        "src/maven.zig",
        "src/nim_config.zig",
        "src/nimble.zig",
        "src/tokens.zig",
        "src/tsconfig.zig",
    } },
    .{ .name = "graph storage and language policy", .patterns = &.{
        "src/code_kind.zig",
        "src/graph_store.zig",
        "src/java_packages.zig",
        "src/lang/go.zig",
        "src/lang/javascript.zig",
        "src/python_exports.zig",
    } },
    .{ .name = "analysis and language dispatch", .patterns = &.{
        "src/analyze.zig",
        "src/languages.zig",
    } },
    .{ .name = "resolution", .patterns = &.{
        "src/Analysis.zig",
        "src/resolve.zig",
    } },
    .{ .name = "owners and scan policy", .patterns = &.{
        "src/Graph.zig",
        "src/recover.zig",
        "src/scan_options.zig",
    } },
    .{ .name = "scanning", .patterns = &.{
        "src/rules.zig",
        "src/scan.zig",
    } },
    .{ .name = "public", .patterns = &.{
        "src/gantry.zig",
    } },
    .{ .name = "fixtures", .patterns = &.{
        "src/test_lexers.zig",
        "src/test_properties.zig",
        "src/test_support.zig",
    } },
    .{ .name = "scenarios", .patterns = &.{
        "src/test_configs.zig",
        "src/test_constraints.zig",
        "src/test_fuzz.zig",
        "src/test_go_modules.zig",
        "src/test_graph.zig",
        "src/test_java.zig",
        "src/test_kinds.zig",
        "src/test_manifests.zig",
        "src/test_memory.zig",
        "src/test_nim.zig",
        "src/test_python_policy.zig",
        "src/test_queries.zig",
        "src/test_recovery.zig",
        "src/test_resolution.zig",
        "src/test_rules.zig",
        "src/test_scan_diagnostic.zig",
        "src/test_tokens.zig",
        "src/test_unsupported.zig",
    } },
    .{ .name = "tests", .patterns = &.{
        "src/tests.zig",
    } },
};

pub const entries: []const []const u8 = &.{};

pub const modules: []const gantry.NamedModule = &.{};
pub const references: []const gantry.rules.ReferenceRule = &.{
    .{ .name = "named dependencies", .unresolved_only = true, .except_targets = &.{
        "std",
    } },
    .{ .name = "source siblings", .suffix = ".zig", .relative = true, .except_targets = &.{"src/**"} },
};

pub const required = blk: {
    var count: usize = 0;
    for (layers) |layer| count += layer.patterns.len;
    var paths: [count][]const u8 = undefined;
    var i: usize = 0;
    for (layers) |layer| for (layer.patterns) |path| {
        paths[i] = path;
        i += 1;
    };
    break :blk paths;
};
