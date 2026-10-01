//! Construction storage for the public analysis owner.
const std = @import("std");
const t = @import("types.zig");
const Analysis = @import("Analysis.zig").Analysis;
const State = @This();
allocator: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
layers: []const t.Layer = &.{},
cycles: []const t.Cycle = &.{},
components: []const []const []const u8 = &.{},

pub fn init(gpa: std.mem.Allocator) !*State {
    const self = try gpa.create(State);
    self.* = .{ .allocator = gpa, .arena = .init(gpa) };
    return self;
}
pub fn deinit(self: *State) void {
    const gpa = self.allocator;
    self.arena.deinit();
    gpa.destroy(self);
}
pub fn owner(self: *State) Analysis {
    return @enumFromInt(@intFromPtr(self)); // safe: the owning handle preserves the allocated state's address.
}
pub fn get(self: Analysis) *State {
    return @ptrFromInt(@intFromEnum(self));
}
