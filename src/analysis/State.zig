//! Construction storage for the public analysis owner.
const reach_module = @import("reach.zig");
const std = @import("std");
const t = @import("../types.zig");
const aegis = @import("aegis");
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

pub fn init(gpa: std.mem.Allocator) std.mem.Allocator.Error!*State {
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
    return @fromBackingInt(@intCast(@intFromPtr(self)));
}
pub fn get(self: anytype) *State {
    const address = @backingInt(self);
    aegis.assert.invariant(address != 0, "address != 0");
    aegis.assert.invariant(address % @alignOf(State) == 0, "address % @alignOf(State) == 0");
    // glint-ignore: P007 -- design: the address owner made from the state this handle owns; the handle is an enum so its state stays behind its accessors
    return @ptrFromInt(address);
}
