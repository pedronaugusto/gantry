# Design

## Invariants

- Graph, imports and analysis handles identify live, aligned allocations. Each
  allocation has one owner; deinit poisons it before releasing its storage.
- Graph paths are normalized, sorted and unique. Pending edge positions refer to
  those paths. Coalesced edges have positive counts and endpoints in the graph.
- Adjacency offsets start at zero, are monotonic, and end at the target count.
  Every target is a node position; optional labels have one element per target.
  Traversal mark and distance arrays have one element per node.
- Lexer token offsets and ends stay within the source and are ordered. Byte
  classification tables cover every u8 value. Template/control stacks retain
  unmatched openings until their matching closing token.
- A scan's recovery slots correspond one to one with graph paths. Cached data
  belongs to graph storage; temporary read and resolution buffers do not escape.
- Progress changes clear the previous byte offset. Diagnostic failure data is
  copied before temporary storage is freed and records the first failure only.
- JSON/report escaping validates UTF-8 before emitting text. Report node
  positions refer to the graph's sorted paths; findings borrow live graph data.

## Semantic domains and public modules

`Edge.count` is an aegis `ReferenceCount`; checked addition maps overflow to
`CountOverflow`. Pending scan endpoints and the path index use one `NodeId`
domain. Importing a node ID does not prove membership in a particular graph:
construction validates sorted paths and coalescing checks endpoint bounds.
Diagnostic progress and output use `ByteOffset`, distinct from occurrence
counts. Recovery offsets remain source-local until explicitly imported into
progress. IDs and counts retain the original scalar layout.

The build exports `gantry.graph`, `gantry.analysis`, `gantry.scan`,
`gantry.imports`, `gantry.rules`, `gantry.manifests`, `gantry.path` and
`gantry.report`. The `gantry` root is a pure declaration facade over those
concerns. Each concern refers downward to one private implementation module;
this preserves declaration identities when callers combine concerns and the
root. The existing source layer graph remains inside that implementation,
with aegis and sweep below it. Unused declarations are lazy: importing a
concern does not compile every operation in the private vocabulary.

## Raw-site decisions

- Pending coalescing retains the native occurrence increment after its input
  slice bounds the total count by `pending.len`. The paired scan workload
  covers this loop; count overflow is impossible within that bound.
- Adjacency and SCC/directory traversal keep raw array indexes in measured
  loops. Construction checks node/target representation limits; offsets,
  targets, labels, marks and distances follow the invariants above.
  These are validated adjacency kernels, not public IDs.
- Lexer/parser offsets and cursor arithmetic address one bounded source
  slice. No unit conversion or independently supplied ID meets them there.
  Parsers validate their format and retain the existing fuzz targets.
- Opaque Graph, Analysis, Imports and immutable slice-result handles are
  safe-type internals: one allocation owns their storage. They are not
  copyable IDs. Explicit deinit and borrow lifetimes stay with the existing
  owners; published aegis scalar types do not add lifetime proof.
- Progress has one synchronous scan owner. It borrows a path only until
  failure capture copies it; Diagnostics owns that copy across cleanup.
- Raw extraction for formatting and constant/bounds comparisons is a scalar
  observation; no different domain participates. The std Io directory limit
  and reader API remain the OS boundary vocabulary.
