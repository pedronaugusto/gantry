//! Construction storage for the public analysis owner.
const reach_module = @import("reach.zig");
const std = @import("std");
const t = @import("../types.zig");
const State = @This();
allocator: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
layers: []const t.Layer = &.{},
cycles: []const t.Cycle = &.{},
components: []const []const []const u8 = &.{},
/// Sorted node paths; positions in them number the adjacency.
paths: []const []const u8 = &.{},
forward: Adjacency = empty,
backward: Adjacency = empty,
coupling: []const t.Coupling = &.{},
directory_coupling: []const t.Coupling = &.{},
const Adjacency = reach_module.Adjacency;
const empty: Adjacency = .{ .offsets = &.{}, .targets = &.{} };

pub fn init(gpa: std.mem.Allocator) !*State {
    const self = try gpa.create(State);
    self.* = .{ .allocator = gpa, .arena = .init(gpa) };
    return self;
}
pub fn deinit(self: *State) void {
    const gpa = self.allocator;
    self.arena.deinit();
    defer gpa.destroy(self);
    self.* = undefined;
}
pub fn owner(comptime Owner: type, self: *State) Owner {
    return @enumFromInt(@intFromPtr(self)); // safe: the owning handle preserves the allocated state's address.
}
pub fn get(self: anytype) *State {
    return @ptrFromInt(@intFromEnum(self));
}
