//! One owner for lexical references and the constructs recovery could not read.
const std = @import("std");
const t = @import("../types.zig");
const State = @This();
arena: std.heap.ArenaAllocator,
recovery: t.Recovery = .{},

pub fn create(gpa: std.mem.Allocator) !*State {
    const state = try gpa.create(State);
    state.* = .{ .arena = .init(gpa) };
    return state;
}
pub fn deinit(state: *State) void {
    const gpa = state.arena.child_allocator;
    state.arena.deinit();
    defer gpa.destroy(state);
    state.* = undefined;
}
pub fn owner(comptime Owner: type, state: *State) Owner {
    return @fromBackingInt(@intCast(@intFromPtr(state))); // safe: the owning handle preserves the allocated state's address.
}
pub fn get(self: anytype) *State {
    const address = @backingInt(self);
    std.debug.assert(address != 0);
    std.debug.assert(address % @alignOf(State) == 0);
    return @ptrFromInt(address);
}
