//! Internal storage shared by immutable slice owners.
const std = @import("std");

pub fn Store(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const State = struct {
            arena: std.heap.ArenaAllocator,
            items: []const T = &.{},

            pub fn deinit(state: *State) void {
                const gpa = state.arena.child_allocator;
                state.arena.deinit();
                gpa.destroy(state);
            }
        };
        /// Move this owner; do not copy it and deinitialize it twice.
        pub const Owner = enum(usize) {
            _,
            /// Borrows read-only results until deinit.
            pub fn items(self: *const Owner) []const T {
                return Self.get(self.*).items;
            }
            pub fn deinit(self: *Owner) void {
                Self.get(self.*).deinit();
                self.* = undefined;
            }
        };
        pub fn create(gpa: std.mem.Allocator) std.mem.Allocator.Error!*State {
            const state = try gpa.create(State);
            state.* = .{ .arena = .init(gpa) };
            return state;
        }
        pub fn owner(state: *State) Owner {
            return @fromBackingInt(@intCast(@intFromPtr(state))); // safe: the owning handle preserves the allocated state's address.
        }
        fn get(self: Owner) *State {
            return @ptrFromInt(@backingInt(self));
        }
    };
}
