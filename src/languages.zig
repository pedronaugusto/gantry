//! The language registry; grammar and resolution live in each module.
pub const zig = @import("lang/zig.zig");
pub const c = @import("lang/c.zig");
pub const javascript = @import("lang/javascript.zig");
pub const python = @import("lang/python.zig");
pub const go = @import("lang/go.zig");
pub const rust = @import("lang/rust.zig");
pub const nim = @import("lang/nim.zig");
