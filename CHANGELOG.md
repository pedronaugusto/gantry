# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Breaking

- Path rules are git's glob dialect, read by sweep, gantry's one dependency: `a/**` is what lies under `a` and no longer matches `a`, brackets (`[ch]`, `[!a-z]`) and `\` escapes are syntax, and `*` and `?` stay within a component as before. Token rules are unchanged: `*` and `?` are the only wildcards. `rules.matches` and `rules.matchesToken` keep their names.
- A rule, test path, named module `from` or token pattern sweep refuses (an unclosed `[`, a trailing `\`, or one past `sweep.Pattern.max_units`) fails: `check` returns `error.InvalidPattern` or `error.PatternTooLong`, both in `rules.CheckError`, whatever the graph holds, and `scan` returns them, both in `ScanError`. Such a pattern matched nothing before.
- `scan` takes an `io` after its allocator and hands it to the reader, which is `read(context, scratch, io, path)`: the value it is called on first, as every method takes it. `DirReader.read(self, scratch, io, path)` follows it, and a reader of another shape fails to compile in `scan` with the expected signature by name. `DirReader` holds no `Io` (`.{ .dir = dir }`); nothing gantry returns keeps one.
- `manifests` names each error set after the function that returns it: `parse` returns `ParseError`, `read` `ReadError` (which now has `UnsupportedManifest`) and `readSupported` `ReadSupportedError`. The module-wide `Error` is gone.
- `scanWithDiagnostic` is gone: set `Options.diagnostics = &diagnostics` and call `scan`. `ScanDiagnostic` is `Diagnostics`.
- `report.sarifWithSource` is gone: `report.sarif(gpa, io, w, findings, context, read, options)` reads the sources when given a reader, and `{}, null` gives none. `report.SourceError(read)` names the errors a reader adds.
- `rules.check` is gone; call `graph.check(gpa, rules)`.
- Every public function returns a named error set: `Graph.InitError`, `Graph.FromEdgesError`, `Graph.AggregateError`, `Analysis.InitError`, `Analysis.QueryError`, `ImportsError` and `WalkError`. `Graph.analyze` and `Analysis.affected` return `std.mem.Allocator.Error`; `affected` skips a path the analysis does not hold, so it never returns `UnknownPath`.
- Allocator parameters are named for what they are: `gpa`, or `arena` where everything allocated shares the caller's lifetime (`manifests.parse`, `read` and `readSupported`).
- Requires Zig 0.17.0.
- Zig imports a test build alone sees are `test` edges: inside a `test` declaration, in the taken branch of `if (builtin.is_test)`, and in a container-level declaration only tests reach. They were `import` edges, so layer and cycle rules over `import` edges no longer see them. An import nothing reaches stays `import`.
- An edge's kind follows its importer. A production file importing a test file gives an `import` edge in Zig, Python, JavaScript/TypeScript, Nim, C and through a Rust `use`; it was a `test` edge, which hid exactly what a rule against production code reaching tests has to catch. The target still makes the edge `test` where an import names more than the file: a Go or Java package import and a Rust `mod` of a `cfg(test)` file.
- `TokenRule.tokens` replaces `token`: one rule names several tokens under one name (`.{ .name = "clock", .tokens = &.{ "nanoTimestamp", "milliTimestamp" } }`). `TokenRule.names(text)` says whether one of them matches.
- A selected file whose bytes are not valid for its format no longer aborts the scan: it is a record in `Graph.invalid()` (`InvalidFile`: path, phase, offset, `FileError` cause) and gives the scan nothing from that phase. A Go file with a bad `//go:build` line is in no package, as `go/build` leaves it; a broken or cyclic JS/TS config is as if absent and its children keep their own options. `scan` fails only with `ScanError` (`InvalidPath`, `UnsupportedImport`, `CountOverflow`, `OutOfMemory`) or the reader's errors, and its return type says so.
- `check` returns an owned `rules.Findings` with `items()` and `deinit()`, which frees transitive findings' chains too. `rules.free` is gone, and `gpa.free` on findings no longer compiles.
- `go.mod` has one reader: module routing and declarations share it, a `require` without a version or an unclosed block is invalid. `manifests.modulePath` is gone.
- A finding's `edge`, `reference` and `token` point into the graph's records instead of copying them: a finding is 104 bytes, down from 240, and field access reads the same.
- Remove `Graph.coalesce`; use `Graph.fromEdges` to validate, sort and coalesce caller edges.
- Hide `Graph`, `Analysis`, `Imports` and `Paths` ownership and storage behind opaque value handles and read-only accessors; use `Graph.contains` for node membership.
- `Analysis.init` now validates and orders inputs through `Graph.fromEdges`, returning explicit path and count errors.

### Added

- `zig build bench` builds the benchmarks in `bench/`: a directory's scan, analysis and aggregation, and every public operation in process. CI compiles them.
- Every declaration of the root module has a doc comment.
- `Reference.dead` and `Spec.dead`: a Zig import in a container-level declaration that nothing reaches, neither a root nor a test, which no build compiles. Every Zig file is read for it, with or without tests.
- `Options.test_paths`: path patterns, in the layer-rule dialect, of files whose every import is `test`, beside each language's own test-file conventions. Zig has none, so its callers name theirs.
- Named error sets: `ScanError`, `FileError`, `ReadError(read)`, `manifests.Error` and `manifests.ReadError`, `rules.CheckError`, `report.Error`, `path.Error`; `DirReader.read` returns `std.Io.Dir.ReadFileAllocError`; `imports` returns `ImportsError`. `manifests.readSupported` reads a path `supported` takes. `Violation.reason` is the named `Violation.Reason`.
- `report.dot`, `mermaid`, `json` and `sarif`: a graph as Graphviz or Mermaid text, clustered by directory or layer, with findings in red; a graph and its findings as JSON of a documented shape; findings as SARIF 2.1.0 for GitHub code scanning, with lines and columns read from the sources.
- `importlib.import_module` and `__import__` with literal names are `dynamic` edges, a relative name resolved against its literal package; other arguments stay unsupported.
- Python imports under `if TYPE_CHECKING:` are `type_only` edges, nested blocks included and `else` branches not.
- Dependency rules: unresolved imports joined to the governing npm, Python, Cargo, Go, Zig, Nim, Maven and Gradle manifests report undeclared packages and unused declarations, with the import or the declaration as evidence.
- Rust paths rooted at a crate's name (`use serde::X`, `extern crate`, `serde_json::f()`) are unresolved references; `go.mod` requirements marked `// indirect` are in group `indirect`.
- Reachable rules: files that no chain from the caller's entry files reaches, orphans included.
- Transitive forbidden rules and ordered layers: a file that reaches a forbidden one through any chain reports the shortest chain as its witness; `rules.free` frees findings with their chains.
- `Analysis.coupling` and `directoryCoupling`: fan-in, fan-out and instability (Ce / (Ca + Ce)) for each file and for every directory above one.
- `Analysis.direct`, `reach`, `affected` and `chain`: what a file depends on or what depends on it, directly or through any chain, the files a change affects, and the shortest chain between two files, in memory linear in the graph.
- Edge kinds `type_only` (TypeScript `import type`, `export type`, all-`type` braces, `import("x")` in a type) and `dynamic` (`import("x")` calls), recorded by default, so a rule can allow type-only edges.
- Fuzz properties for every lexer and every manifest and config reader; `zig build test` runs their seeds.
- Token rules: an identifier or string value only its owners' files may spell, recorded from the token streams the scan lexes anyway and checked with path, line and column.
- `Dependency.shortName`: the package's own name without its namespace (Maven and Gradle artifact, Go module path element before a major version, npm scope).
- Recover Java imports and package declarations, resolved through the packages selected files declare; `Class.forName` and `loadClass` calls are unsupported.
- Read `pom.xml` dependencies with their scope through the file's own properties (`<optional>` is optional scope outside `test`), and literal `build.gradle` and `build.gradle.kts` declarations; computed declarations are unsupported.
- Recover Nim `import`, `include` and `from` modules, resolved beside the importer and on the literal search paths of selected Nim configs.
- Read `.nimble` requirements, named in `manifests.extensions`. `manifests.read` also returns the declarations a manifest spells in a form it cannot read, and scans record them as unsupported.
- `Dependency.origin` records whether a declaration comes from a registry, a local folder, a remote or the workspace, from the key or form that named it; `Dependency.revision` is the pin a remote source spells.
- `Dependency.scope` says whether a declaration is for running, development, an optional extra or building, from its manifest's groups.
- `kindsOf` says which reference kinds a scan reads from a path, and the scan selects files by it.
- `manifests.names` lists the manifest file names `manifests.parse` reads.
- Record detectable unsupported imports in `Imports` and `Graph`, and reject them with `Options.strict_imports` and a diagnostic byte offset.
- Caller-owned `Diagnostics` output, through `Options.diagnostics`, with the failed file, phase and original cause while keeping graph results atomic.
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

### Changed

- A check compiles each pattern once, finds each path's layer once, and a scan matches test paths once per file: `rules/forbidden` and `rules/nothing-imports` run 7.5 times faster, `rules/allowed` 6 times, transitive rules 2.5 times, ordered layers 1.8 times. `rules.matches` and `rules.matchesToken` match one pattern once, `rules.matches` in half the time it took and `rules.matchesToken` in no more; a caller matching one many times compiles it with `sweep.Pattern` and `rules.patternOptions`.
- Zig: `if (x.is_test)` is a test branch only when `x` is `@import("builtin")` or a container-level `const` bound to it, so `if (options.is_test)` keeps its imports `import`. Decl and enum literals (`return .default;`, `x = .empty`) and `@field(@This(), "name")` reach the declaration they name, where before such a declaration could be read as test-only or unreached. The label in `break :blk` is no reference.
- Paths refuse only a drive spelling (`C:` at the start), not every colon; `walk` skips names a scan would refuse. `path.valid` says whether `normalize` takes a path.
- Take a Zig import path as written when it has no escape, and look for alias members only in files that declare an alias.
- Find Python loader calls across line breaks without copying the token stream.
- Look up the JavaScript keywords that decide regular expressions in one table, and only when lexing JavaScript.
- Grow token streams by the density of the text already read, so a long file's stream moves a few times instead of at every half again.
- Lex Go, Zig, JavaScript, Rust and Java without the newline tokens their recovery drops.
- Drop newline tokens in place rather than copying each token stream.
- Keep at most 1 MiB of scan scratch between files: a large file's tokens are released before the next file is read.
- Hold scan edges as path positions until they are coalesced, so graph storage keeps no outgrown edge lists.
- Store recovered reference names once and index scan recovery by selected file.
- Reuse Python recovery for literal reexports and imports without retaining source buffers.
- Read and lex Go sources once for build constraints and import recovery.
- Reuse Rust recovery for test classification and imports, reading each source once.
- Reject undeclared dependencies, duplicate layer membership and imports of source executables.
- Scanning stays linear in hostile input: Markdown wiki links stay on their line and code spans find their closer from an index of backtick runs; XML entity names and C++ raw-string delimiters are searched within their bounds; Go import blocks and Rust use trees are read once.
- Document that rule findings borrow required-path strings as well as graph storage and rule names.

### Fixed

- A token pattern's `*` no longer matches a literal `*` in the text as one byte and stops there: `*a` matches `*ba`.
- TOML array-of-tables headers (`[[bin]]`, `[[tool.mypy.overrides]]`) and dotted keys under a Cargo dependency table (`serde.features = [...]`, `local.path = "../x"`) are read instead of failing the manifest.
- A dependency whose imports resolve to selected files (a Go `replace` or workspace member, a Zig path dependency under a named module) is used, not reported unused.
- A single- or double-quoted literal that cannot span lines ends at its newline when unclosed, so an apostrophe in JSX text or `#if 0` prose no longer hides the imports after it.
- A leading UTF-8 byte order mark is skipped by the lexers, the JSON readers and Go constraints.
- Markdown link destinations are percent-decoded (`my%20file.md`). Zig `@import("x.zon")` resolves beside the importer.
- Rust `use util::X` resolves to `util.rs` when the current module declares `mod util;`, as rustc's 2018 paths do, and gives no edge beside an `extern crate util`.
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

[Unreleased]: https://github.com/pedronaugusto/gantry/commits/main
