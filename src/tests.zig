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
    _ = @import("lexers_test.zig");
    _ = @import("unsupported_test.zig");
    _ = @import("resolution_test.zig");
    _ = @import("configs_test.zig");
    _ = @import("scan_diagnostic_test.zig");
    _ = @import("go_modules_test.zig");
    _ = @import("kinds_test.zig");
    _ = @import("constraints_test.zig");
    _ = @import("python_policy_test.zig");
    _ = @import("graph_test.zig");
    _ = @import("rules_test.zig");
    _ = @import("report_test.zig");
    _ = @import("queries_test.zig");
    _ = @import("dependencies_test.zig");
    _ = @import("tokens_test.zig");
    _ = @import("fuzz_test.zig");
    _ = @import("manifests_test.zig");
    _ = @import("nim_test.zig");
    _ = @import("java_test.zig");
    _ = @import("recovery_test.zig");
    _ = @import("properties_test.zig");
    _ = @import("memory_test.zig");
}
