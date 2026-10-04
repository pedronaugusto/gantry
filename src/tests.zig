const std = @import("std");
const g = @import("gantry.zig");
test "empty graph owns its result" {
    var graph = try g.scan(std.testing.allocator, &.{}, {}, struct {
        fn read(_: void, _: []const u8, _: std.mem.Allocator) !?[]const u8 {
            return "";
        }
    }.read, .{});
    defer graph.deinit();
    var a = try graph.analyze(std.testing.allocator);
    defer a.deinit();
    try std.testing.expectEqual(0, a.layers().len);
}

test {
    _ = @import("testing/lexers_test.zig");
    _ = @import("testing/unsupported_test.zig");
    _ = @import("testing/resolution_test.zig");
    _ = @import("testing/configs_test.zig");
    _ = @import("scan/diagnostic_test.zig");
    _ = @import("testing/go_modules_test.zig");
    _ = @import("testing/kinds_test.zig");
    _ = @import("testing/constraints_test.zig");
    _ = @import("testing/python_policy_test.zig");
    _ = @import("Graph_test.zig");
    _ = @import("rules_test.zig");
    _ = @import("report_test.zig");
    _ = @import("testing/queries_test.zig");
    _ = @import("testing/dependencies_test.zig");
    _ = @import("tokens_test.zig");
    _ = @import("testing/fuzz_test.zig");
    _ = @import("manifests_test.zig");
    _ = @import("lang/nim_test.zig");
    _ = @import("lang/java_test.zig");
    _ = @import("testing/recovery_test.zig");
    _ = @import("testing/properties_test.zig");
    _ = @import("testing/memory_test.zig");
}
