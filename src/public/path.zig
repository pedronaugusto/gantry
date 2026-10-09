//! Path vocabulary; the package owns each declaration once.
const concern = @import("implementation").path;
/// See `gantry.path.Error`.
pub const Error = concern.Error;
/// See `gantry.path.normalize`.
pub const normalize = concern.normalize;
/// See `gantry.path.valid`.
pub const valid = concern.valid;
/// See `gantry.path.dir`.
pub const dir = concern.dir;
/// See `gantry.path.base`.
pub const base = concern.base;
/// See `gantry.path.within`.
pub const within = concern.within;
/// See `gantry.path.directory`.
pub const directory = concern.directory;
