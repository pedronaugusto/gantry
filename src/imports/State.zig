//! One owner for lexical references and the constructs recovery could not read.
const std = @import("std");
const t = @import("../types.zig");
const aegis = @import("aegis");
const State = @This();
arena: std.heap.ArenaAllocator,
recovery: t.Recovery = .{},

pub fn create(gpa: std.mem.Allocator) std.mem.Allocator.Error!*State {
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
    return @fromBackingInt(@intCast(@intFromPtr(state)));
}
pub fn get(self: anytype) *State {
    const address = @backingInt(self);
    aegis.assert.invariant(address != 0, "address != 0");
    aegis.assert.invariant(address % @alignOf(State) == 0, "address % @alignOf(State) == 0");
    // glint-ignore: P007 -- design: the address owner made from the state this handle owns; the handle is an enum so its state stays behind its accessors
    return @ptrFromInt(address);
}
