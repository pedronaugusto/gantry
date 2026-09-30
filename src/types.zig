const std = @import("std");
pub const Language = enum { zig, c, javascript, python, go, rust };
pub const Kind = enum { import, link, asset, @"test" };
pub const Edge = struct { from: []const u8, to: []const u8, kind: Kind = .import, count: usize = 1 };
pub const Form = enum { literal, python, rust_mod, rust_use };
/// Raw references borrow the source or the allocator passed to the lexer.
pub const Spec = struct { name: []const u8, offset: usize, form: Form = .literal, member: ?[]const u8 = null, kind: Kind = .import, scope: []const u8 = "" };
pub const Reference = struct { from: []const u8, name: []const u8, offset: usize, member: ?[]const u8 = null, resolved: bool = false, kind: Kind = .import };
pub const Dependency = struct { manifest: []const u8, name: []const u8, requirement: []const u8 = "", source: []const u8 = "", group: []const u8 = "dependencies" };
pub const Layer = struct { path: []const u8, depth: usize };
pub const Cycle = struct { members: []const []const u8, path: []const []const u8 };
pub fn stringsLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}
pub fn edgesLess(_: void, a: Edge, b: Edge) bool {
    const from = std.mem.order(u8, a.from, b.from);
    if (from != .eq) return from == .lt;
    const to = std.mem.order(u8, a.to, b.to);
    if (to != .eq) return to == .lt;
    return @intFromEnum(a.kind) < @intFromEnum(b.kind);
}
