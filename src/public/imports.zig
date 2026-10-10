//! Imports declarations, sharing the package's allocation and scalar identities.
const implementation = @import("implementation");
/// See the package contract for `Language`.
pub const Language = implementation.Language;
/// See the package contract for `Spec`.
pub const Spec = implementation.Spec;
/// See the package contract for `Imports`.
pub const Imports = implementation.Imports;
/// See the package contract for `imports`.
pub const imports = implementation.imports;
/// See the package contract for `importsWith`.
pub const importsWith = implementation.importsWith;
/// See the package contract for `ImportsError`.
pub const ImportsError = implementation.ImportsError;
/// See the package contract for `languageOf`.
pub const languageOf = implementation.languageOf;
