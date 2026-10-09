const gantry = @import("gantry");
pub export fn wrongOffset(value: usize) usize {
    const failure: gantry.Diagnostics.Failure = .{ .path = null, .phase = .imports, .cause = error.UnsupportedImport, .offset = gantry.ReferenceCount.fromRaw(value) };
    return failure.offset.?.raw();
}
