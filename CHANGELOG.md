# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

- Keep the quiet benchmark worktree outside Zig’s disposable cache.
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
