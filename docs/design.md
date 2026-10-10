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

## Frontends

A language gantry's byte lexers do not read is read by a frontend, a module
that yields a file's `Recovery` (references with kind and liveness, and the
constructs it cannot read) and, when token rules ask, the units of its tokens
to an `Observer`. The vocabulary (`src/frontend.zig`, the namespace
`gantry.frontend`) is below everything else and imports only std. A frontend
module imports `gantry` for it, and the core imports no frontend, so they share
its types with the dependency running one way. Resolution
of a reference to files stays in the core, which knows the selected paths. A
scan lists its frontends in `Options.frontends`; a path in a language that
needs one without it is `FrontendMissing`, decided before any file is read, so
an unread language is an error and never an empty file.

`gantry.zig` is the Zig frontend on glint's token tier (std's tokenizer, no
parse tree). It is built only when `zig` is set on the dependency, so a project
that never analyses Zig fetches no glint. A semantic tier (resolved calls, for
an ownership policy that lexing cannot give) would be a second use of glint
behind the same seam, asked for only by the policy that needs it. The observer
of a token rule gets a Zig stream of words (a name, keyword or number), strings
and punctuation, with an `@"name"` as one word and an operator whole; the
bridge keeps the last two units only, which is all an observer reads.

## Semantic domains and public modules

`Edge.count` is an aegis `ReferenceCount`; checked addition maps overflow to
`CountOverflow`. Pending scan endpoints and the path index use one `NodeId`
domain. Importing a node ID does not prove membership in a particular graph:
construction validates sorted paths and coalescing checks endpoint bounds.
Diagnostic progress and output use `ByteOffset`, distinct from occurrence
counts. Recovery offsets remain source-local until explicitly imported into
progress. IDs and counts retain the original scalar layout. Named domain markers keep
compiler diagnostics stable; compile-fail checks match semantic type errors
without host paths or generated anonymous-struct numbers.

`gantry` is one module. Its concerns (`rules`, `manifests`, `path`, `report` and
`frontend`) are namespaces of it, beside the graph, analysis, scan and import
declarations the root names directly: no concern has a dependency a user should
not fetch, and Zig compiles only what a program uses, so separate modules would
buy nothing but a second path to the same declaration. The source layers inside
it are what `ci/layers.zig` enforces, with aegis and sweep below. The one other
module is `gantry.zig`, which needs glint and imports the root; a module of its
own is what keeps glint from being fetched by a user who never reads Zig.

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

## Adoption gate

`ci/preflight.json` selects `ci/glint.json` through `glint_config` and lists
all Zig source roots through `glint_paths`, including tests, benchmarks,
examples and CI programs. The package requires A004 in gate mode for its
adopted ID, count and checked-integer domains; there are no test or benchmark
exclusions. The family profile retains the other reviewed rule selections.

The pinned published preflight still runs ziglint and does not consume these
Glint settings. They become active with G4 integration. Published Glint G3
also rejects A004 gate selection as report-only; that restriction must be
reconciled with the package gate contract before enforcement is claimed.
