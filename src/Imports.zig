//! Owned lexical recovery from an anonymous source buffer.
const t = @import("types.zig");
const store = @import("import_store.zig");

/// Move this owner; do not copy it and deinitialize it twice.
pub const Imports = enum(usize) {
    _,
    /// Borrows read-only recovered references until deinit.
    pub fn items(self: *const Imports) []const t.Spec {
        return store.get(self.*).recovery.specs;
    }
    /// Import-shaped constructs outside lexical recovery. Source paths are null
    /// because `imports` receives anonymous bytes; scans supply selected paths.
    pub fn unsupported(self: *const Imports) []const t.UnsupportedReference {
        return store.get(self.*).recovery.unsupported;
    }
    pub fn deinit(self: *Imports) void {
        store.get(self.*).deinit();
        self.* = undefined;
    }
};
