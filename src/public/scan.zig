//! Scan declarations, sharing the package's allocation and scalar identities.
const implementation = @import("implementation");
/// See the package contract for `Options`.
pub const Options = implementation.Options;
/// See the package contract for `scan`.
pub const scan = implementation.scan;
/// See the package contract for `kindsOf`.
pub const kindsOf = implementation.kindsOf;
/// See the package contract for `Diagnostics`.
pub const Diagnostics = implementation.Diagnostics;
/// See the package contract for `ScanError`.
pub const ScanError = implementation.ScanError;
/// See the package contract for `ReadError`.
pub const ReadError = implementation.ReadError;
/// See the package contract for `InvalidFile`.
pub const InvalidFile = implementation.InvalidFile;
/// See the package contract for `FileError`.
pub const FileError = implementation.FileError;
/// See the package contract for `DirReader`.
pub const DirReader = implementation.DirReader;
/// See the package contract for `Paths`.
pub const Paths = implementation.Paths;
/// See the package contract for `walk`.
pub const walk = implementation.walk;
/// See the package contract for `WalkError`.
pub const WalkError = implementation.WalkError;
/// See the package contract for `PythonInitializers`.
pub const PythonInitializers = implementation.PythonInitializers;
/// See the package contract for `GoTarget`.
pub const GoTarget = implementation.GoTarget;
/// See the package contract for `NamedModule`.
pub const NamedModule = implementation.NamedModule;
