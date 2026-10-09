const gantry = @import("gantry");
pub export fn wrongCount(value: usize) usize {
    const edge: gantry.Edge = .{ .from = "a", .to = "b", .count = value };
    return edge.count.raw();
}
