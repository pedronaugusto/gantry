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

## Zig facts

- glint owns every Zig fact: std's parser and lowering read a file, and glint says where
  each name resolves, in which context each import and reference sits, and which calls
  it can resolve. gantry owns what it does with them: which spelling is which file,
  which edges a scan records, and which imports only a test build sees or no build
  analyses. It has no Zig lexer, scope or type code; the lexer that remains feeds the
  token rules, which read every language's tokens alike.
- A file is read alone: gantry maps no module for glint, so every import is
  `missing_mapping` in the projection and gantry resolves the spelling itself, in its
  path dialect. Nothing in a file's facts depends on another file.
- A file glint cannot read has no facts and none are guessed: it is a record in
  `Graph.invalid()`. glint reports an import of a non-literal, an invalid escape and an
  unused local as lowering errors, so gantry has no unsupported Zig import.
- What glint leaves unknown is read towards production. A call it cannot resolve, a decl
  literal and a `@field` name may reach any container-level declaration of that name; a
  `test name {}` reaches `name`. An unknown never makes an import `test` or `dead`.
- A container-level declaration is live from `pub`, `export`, `main`, fields and
  `comptime` blocks, test-only from `test` declarations, `if (builtin.is_test)` branches
  and what they reach, and dead otherwise. Edges between declarations come from
  glint's resolved references and calls, never from spellings.
- Recovery of a scan's Zig files starts before the scan reads them and is taken in path
  order: the graph is the same whatever the schedule. Source copies are held up to
  128 MiB; the files past that are recovered one at a time when the scan reaches them.
  The calling task recovers fewer than sixteen files itself.
