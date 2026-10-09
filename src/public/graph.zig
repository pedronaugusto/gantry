//! Graph declarations, sharing the package's allocation and scalar identities.
const implementation = @import("implementation");
/// See the package contract for `Graph`.
pub const Graph = implementation.Graph;
/// See the package contract for `Kind`.
pub const Kind = implementation.Kind;
/// See the package contract for `Edge`.
pub const Edge = implementation.Edge;
/// See the package contract for `ReferenceCount`.
pub const ReferenceCount = implementation.ReferenceCount;
/// See the package contract for `ByteOffset`.
pub const ByteOffset = implementation.ByteOffset;
/// See the package contract for `Reference`.
pub const Reference = implementation.Reference;
/// See the package contract for `Token`.
pub const Token = implementation.Token;
/// See the package contract for `UnsupportedReference`.
pub const UnsupportedReference = implementation.UnsupportedReference;
/// See the package contract for `ImportExpression`.
pub const ImportExpression = implementation.ImportExpression;
/// See the package contract for `Dependency`.
pub const Dependency = implementation.Dependency;
/// See the package contract for `GoFile`.
pub const GoFile = implementation.GoFile;
