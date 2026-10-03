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
    _ = @import("test_lexers.zig");
    _ = @import("test_unsupported.zig");
    _ = @import("test_resolution.zig");
    _ = @import("test_configs.zig");
    _ = @import("test_scan_diagnostic.zig");
    _ = @import("test_go_modules.zig");
    _ = @import("test_kinds.zig");
    _ = @import("test_constraints.zig");
    _ = @import("test_python_policy.zig");
    _ = @import("test_graph.zig");
    _ = @import("test_rules.zig");
    _ = @import("test_queries.zig");
    _ = @import("test_tokens.zig");
    _ = @import("test_fuzz.zig");
    _ = @import("test_manifests.zig");
    _ = @import("test_nim.zig");
    _ = @import("test_java.zig");
    _ = @import("test_recovery.zig");
    _ = @import("test_properties.zig");
    _ = @import("test_memory.zig");
}
