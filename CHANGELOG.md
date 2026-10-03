# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

- Take a Zig import path as written when it has no escape, and look for alias members only in files that declare an alias.

- Find Python loader calls across line breaks without copying the token stream.

- Look up the JavaScript keywords that decide regular expressions in one table, and only when lexing JavaScript.

- Grow token streams by the density of the text already read, so a long file's stream moves a few times instead of at every half again.

- Lex Go, Zig, JavaScript, Rust and Java without the newline tokens their recovery drops.

- Fuzz properties for every lexer and every manifest and config reader; `zig build test` runs their seeds.

- Token rules: an identifier or string value only its owners' files may spell, recorded from the token streams the scan lexes anyway and checked with path, line and column.

- `Dependency.shortName`: the package's own name without its namespace (Maven and Gradle artifact, Go module path element before a major version, npm scope).

- Drop newline tokens in place rather than copying each token stream.

- Keep at most 1 MiB of scan scratch between files: a large file's tokens are released before the next file is read.

- Hold scan edges as path positions until they are coalesced, so graph storage keeps no outgrown edge lists.

- Recover Java imports and package declarations, resolved through the packages selected files declare; `Class.forName` and `loadClass` calls are unsupported.

- Read `pom.xml` dependencies with their scope through the file's own properties (`<optional>` is optional scope outside `test`), and literal `build.gradle` and `build.gradle.kts` declarations; computed declarations are unsupported.

- Recover Nim `import`, `include` and `from` modules, resolved beside the importer and on the literal search paths of selected Nim configs.

- Read `.nimble` requirements, named in `manifests.extensions`. `manifests.read` also returns the declarations a manifest spells in a form it cannot read, and scans record them as unsupported.

- `Dependency.origin` records whether a declaration comes from a registry, a local folder, a remote or the workspace, from the key or form that named it; `Dependency.revision` is the pin a remote source spells.

- `Dependency.scope` says whether a declaration is for running, development, an optional extra or building, from its manifest's groups.

- `kindsOf` says which reference kinds a scan reads from a path, and the scan selects files by it.

- `manifests.names` lists the manifest file names `manifests.parse` reads.

- Store recovered reference names once and index scan recovery by selected file.

- Reuse Python recovery for literal reexports and imports without retaining source buffers.

- Read and lex Go sources once for build constraints and import recovery.

- Reuse Rust recovery for test classification and imports, reading each source once.

- Reject undeclared dependencies, duplicate layer membership and imports of source executables.

- Keep owner conversions, graph analysis, rule evaluation and scan inputs below their public facades, and assemble tests above them.

- Check named source layers, cycles, entry files and dependency owners during source CI.

- Bound local Zig build caches before builds, retaining downloaded packages and tools.

### Changed

- Breaking: remove `Graph.coalesce`; use `Graph.fromEdges` to validate, sort and coalesce caller edges.

- Breaking: hide `Graph`, `Analysis`, `Imports` and `Paths` ownership and storage behind opaque value handles and read-only accessors; use `Graph.contains` for node membership.
- Breaking: `Analysis.init` now validates and orders inputs through `Graph.fromEdges`, returning explicit path and count errors.
- Document that rule findings borrow required-path strings as well as graph storage and rule names.

### Fixed

- Report an empty or truncated `tsconfig.json` or `jsconfig.json` as `SyntaxError`, like other invalid JSONC, rather than the JSON reader's own error.
- Free the lexer's own call and template stacks, so a caller's allocator gets back everything but the tokens.
- Preserve JS template boundaries so interpolation strings cannot become literal import operands.
- Omit guessed default Rust module edges when a path attribute controls the source file.

- Return `InvalidConfig` for malformed JS/TS config roots and resolution field types instead of silently ignoring them.
- Keep absolute reference and config paths unresolved through one repository-relative resolution join instead of interpreting them beside the source or config.
- Parse JSONC configs with JSON-specific comment and comma handling, rejecting source syntax and unterminated comments instead of dropping them.
- Validate whole ZON documents before reading root dependencies, decode quoted fields and multiline strings, and return `InvalidManifest` for malformed input.
- Record every null read once in `graph.unread()`, including resolution passes and assets with manifest declarations disabled.
- Reset reader scratch after every config and preprocessing read, including null results, instead of retaining source buffers across files.
- Release resolution configs and indexes when a scan returns, keeping construction workspaces out of the graph's owned storage.

### Added

- Record detectable unsupported imports in `Imports` and `Graph`, and reject them with `Options.strict_imports` and a diagnostic byte offset.

- Add `scanWithDiagnostic` and caller-owned `ScanDiagnostic` output with the failed file, phase and original cause while keeping graph results atomic.

- Caller-selected files and readers, with directory reading and walking helpers.
- Import lexers and resolution for Zig, C/C++, JS/TS, Python, Go and Rust.
- Markdown link and asset path recovery, and direct manifest declarations.
- Owned graphs, directory aggregation, SCCs, cycle witnesses and longest depths.
- Layer, edge, entry-file, named-import, member-access, presence and cycle rules.
- Repository JS/TS config inheritance, path aliases and declaration substitution.
- Local Go workspace and replacement routing, with recorded build constraints
  and explicit caller targets.
- Test edge kinds and kind-based rule allowances.
- Selectable Python initializer policies and literal export-list reexports.
- Agreement results against pinned repositories and language tools.
