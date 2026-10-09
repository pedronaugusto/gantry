//! Manifests vocabulary; the package owns each declaration once.
const concern = @import("implementation").manifests;
/// See `gantry.manifests.names`.
pub const names = concern.names;
/// See `gantry.manifests.extensions`.
pub const extensions = concern.extensions;
/// See `gantry.manifests.supported`.
pub const supported = concern.supported;
/// See `gantry.manifests.Declarations`.
pub const Declarations = concern.Declarations;
/// See `gantry.manifests.ReadSupportedError`.
pub const ReadSupportedError = concern.ReadSupportedError;
/// See `gantry.manifests.ReadError`.
pub const ReadError = concern.ReadError;
/// See `gantry.manifests.ParseError`.
pub const ParseError = concern.ParseError;
/// See `gantry.manifests.parse`.
pub const parse = concern.parse;
/// See `gantry.manifests.read`.
pub const read = concern.read;
/// See `gantry.manifests.readSupported`.
pub const readSupported = concern.readSupported;
