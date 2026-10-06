const lexers_test_module = @import("testing/lexers_test.zig");
const unsupported_test_module = @import("testing/unsupported_test.zig");
const resolution_test_module = @import("testing/resolution_test.zig");
const configs_test_module = @import("testing/configs_test.zig");
const diagnostic_test_module = @import("scan/diagnostic_test.zig");
const go_modules_test_module = @import("testing/go_modules_test.zig");
const kinds_test_module = @import("testing/kinds_test.zig");
const constraints_test_module = @import("testing/constraints_test.zig");
const python_policy_test_module = @import("testing/python_policy_test.zig");
const graph_test_module = @import("graph_test.zig");
const rules_test_module = @import("rules_test.zig");
const report_test_module = @import("report_test.zig");
const queries_test_module = @import("testing/queries_test.zig");
const dependencies_test_module = @import("testing/dependencies_test.zig");
const tokens_test_module = @import("tokens_test.zig");
const fuzz_test_module = @import("testing/fuzz_test.zig");
const manifests_test_module = @import("manifests_test.zig");
const nim_test_module = @import("lang/nim_test.zig");
const java_test_module = @import("lang/java_test.zig");
const zig_test_module = @import("lang/zig_test.zig");
const recovery_test_module = @import("testing/recovery_test.zig");
const properties_test_module = @import("testing/properties_test.zig");
const memory_test_module = @import("testing/memory_test.zig");
const hostile_test_module = @import("testing/hostile_test.zig");
const std = @import("std");
const g = @import("gantry.zig");
test "empty graph owns its result" {
    var graph = try g.scan(std.testing.allocator, &.{}, {}, struct {
        fn read(_: std.mem.Allocator, _: void, _: []const u8) !?[]const u8 {
            return "";
        }
    }.read, .{});
    defer graph.deinit();
    var a = try graph.analyze(std.testing.allocator);
    defer a.deinit();
    try std.testing.expectEqual(0, a.layers().len);
}

test {
    _ = lexers_test_module;
    _ = hostile_test_module;
    _ = unsupported_test_module;
    _ = resolution_test_module;
    _ = configs_test_module;
    _ = diagnostic_test_module;
    _ = go_modules_test_module;
    _ = kinds_test_module;
    _ = constraints_test_module;
    _ = python_policy_test_module;
    _ = graph_test_module;
    _ = rules_test_module;
    _ = report_test_module;
    _ = queries_test_module;
    _ = dependencies_test_module;
    _ = tokens_test_module;
    _ = fuzz_test_module;
    _ = manifests_test_module;
    _ = nim_test_module;
    _ = java_test_module;
    _ = zig_test_module;
    _ = recovery_test_module;
    _ = properties_test_module;
    _ = memory_test_module;
}
