# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Breaking: hide `Graph`, `Analysis`, `Imports` and `Paths` ownership and storage behind opaque value handles and read-only accessors; use `Graph.contains` for node membership.

- Breaking: `Analysis.init` now validates and orders inputs through `Graph.fromEdges`, returning explicit path and count errors.
- Document that rule findings borrow required-path strings as well as graph storage and rule names.

### Fixed

- Validate whole ZON documents before reading root dependencies, decode quoted fields and multiline strings, and return `InvalidManifest` for malformed input.

- Record every null read once in `graph.unread()`, including resolution passes and assets with manifest declarations disabled.
- Reset reader scratch after every config and preprocessing read, including null results, instead of retaining source buffers across files.
- Release resolution configs and indexes when a scan returns, keeping construction workspaces out of the graph's owned storage.

### Added

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
