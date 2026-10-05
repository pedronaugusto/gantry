# Invariants

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
