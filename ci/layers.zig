//! Source layers, lowest first. Every source has one explicit place.
const gantry = @import("gantry");

pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "primitives", .patterns = &.{
        "src/builtins.zig",
        "src/frontend.zig",
        "src/jsonc.zig",
        "src/owned_slice.zig",
        "src/path.zig",
        "src/scan/diagnostic.zig",
        "src/types.zig",
    } },
    .{ .name = "storage and matching", .patterns = &.{
        "src/analysis/State.zig",
        "src/imports/State.zig",
        "src/lexer.zig",
        "src/analysis/reach.zig",
        "src/resolve/path.zig",
        "src/rules/check.zig",
        "src/scan/reader.zig",
    } },
    .{ .name = "recovery and configuration", .patterns = &.{
        "src/imports.zig",
        "src/lang/go/build.zig",
        "src/lang/go/config.zig",
        "src/manifests/**",
        "src/lang/c.zig",
        "src/lang/java.zig",
        "src/lang/nim.zig",
        "src/lang/python.zig",
        "src/lang/rust.zig",
        "src/lang/zig.zig",
        "src/manifests.zig",
        "src/lang/nim/config.zig",
        "src/tokens.zig",
        "src/tsconfig.zig",
    } },
    .{ .name = "graph storage and language policy", .patterns = &.{
        "src/code_kind.zig",
        "src/graph/Storage.zig",
        "src/lang/java/packages.zig",
        "src/lang/go.zig",
        "src/lang/javascript.zig",
        "src/lang/python/exports.zig",
    } },
    .{ .name = "analysis and language dispatch", .patterns = &.{
        "src/analysis/analyze.zig",
        "src/lang.zig",
    } },
    .{ .name = "resolution", .patterns = &.{
        "src/analysis.zig",
        "src/resolve.zig",
    } },
    .{ .name = "owners and scan policy", .patterns = &.{
        "src/graph.zig",
        "src/rules/dependency_check.zig",
        "src/recover.zig",
        "src/scan/options.zig",
    } },
    .{ .name = "scanning", .patterns = &.{
        "src/rules.zig",
        "src/scan.zig",
    } },
    .{ .name = "reports", .patterns = &.{
        "src/report.zig",
        "src/report/**",
    } },
    .{ .name = "public root", .patterns = &.{"src/gantry.zig"} },
    .{ .name = "frontends", .patterns = &.{"src/frontends/**"} },
};

pub const entries: []const []const u8 = &.{};

pub const modules: []const gantry.NamedModule = &.{
    .{ .name = "gantry", .path = "src/gantry.zig", .from = "src/frontends/**" },
    .{ .name = "zig_frontend", .path = "src/frontends/zig.zig", .from = "src/testing/**" },
};

const package_references = [_]gantry.rules.ReferenceRule{
    .{ .name = "named dependencies", .unresolved_only = true, .except_targets = &.{
        "std",
        "aegis",
        "sweep",
        "glint",
        "shakedown",
    } },
    .{ .name = "source siblings", .suffix = ".zig", .relative = true, .except_targets = &.{"src/**"} },
};

pub const references: []const gantry.rules.ReferenceRule = &package_references;
pub const owned: []const gantry.rules.TokenRule = &(durability ++ no_async);

pub const required = [_][]const u8{
    "src/builtins.zig",
    "src/frontend.zig",
    "src/jsonc.zig",
    "src/owned_slice.zig",
    "src/path.zig",
    "src/scan/diagnostic.zig",
    "src/types.zig",
    "src/analysis/State.zig",
    "src/imports/State.zig",
    "src/lexer.zig",
    "src/analysis/reach.zig",
    "src/resolve/path.zig",
    "src/rules/check.zig",
    "src/scan/reader.zig",
    "src/imports.zig",
    "src/lang/go/build.zig",
    "src/lang/go/config.zig",
    "src/manifests/gradle.zig",
    "src/lang/c.zig",
    "src/lang/java.zig",
    "src/lang/nim.zig",
    "src/lang/python.zig",
    "src/lang/rust.zig",
    "src/lang/zig.zig",
    "src/manifests.zig",
    "src/manifests/maven.zig",
    "src/lang/nim/config.zig",
    "src/manifests/nimble.zig",
    "src/tokens.zig",
    "src/tsconfig.zig",
    "src/code_kind.zig",
    "src/graph/Storage.zig",
    "src/lang/java/packages.zig",
    "src/lang/go.zig",
    "src/lang/javascript.zig",
    "src/lang/python/exports.zig",
    "src/analysis/analyze.zig",
    "src/lang.zig",
    "src/analysis.zig",
    "src/resolve.zig",
    "src/graph.zig",
    "src/rules/dependency_check.zig",
    "src/recover.zig",
    "src/scan/options.zig",
    "src/rules.zig",
    "src/scan.zig",
    "src/report.zig",
    "src/report/json.zig",
    "src/frontends/zig.zig",
    "src/gantry.zig",
    "src/tests.zig",
};

/// Durable writes go through airlock.
const durability = [_]gantry.rules.TokenRule{.{
    .name = "durability belongs to airlock",
    .sequences = &.{
        &.{ ".", "sync", "(" },
        &.{ ".", "syncFile", "(" },
        &.{ ".", "syncDir", "(" },
        &.{ "createFileAtomic", "(" },
        &.{ "fsync", "(" },
        &.{ "fdatasync", "(" },
        &.{ "FlushFileBuffers", "(" },
    },
}};

/// The caller owns asynchronous work.
const no_async = [_]gantry.rules.TokenRule{.{
    .name = "async belongs to the caller",
    .sequences = &.{&.{ "io", ".", "async", "(" }},
}};
