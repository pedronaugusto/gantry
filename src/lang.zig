//! The language registry; grammar and resolution live in each module.
pub const zig = @import("lang/zig.zig");
pub const c = @import("lang/c.zig");
pub const javascript = @import("lang/javascript.zig");
pub const python = @import("lang/python.zig");
pub const go = @import("lang/go.zig");
pub const rust = @import("lang/rust.zig");
pub const nim = @import("lang/nim.zig");
pub const java = @import("lang/java.zig");

const Self = @This();
const Language = @import("types.zig").Language;
/// Whether a language's recovery is a frontend's, because it needs more than
/// the byte lexers here can give. Zig reads through glint, in `gantry.zig`.
pub fn readsThroughFrontend(comptime language: Language) bool {
    return !@hasDecl(@field(Self, @tagName(language)), "recoverTokens");
}
