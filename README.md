# gantry

gantry recovers file dependencies from caller-selected source files, Markdown links and
asset paths in Zig. It returns a graph with directory aggregation, layers, cycle
witnesses and checks against caller-defined boundaries.

## Install

Requires Zig 0.16.0. Fetch with `zig fetch --save
git+https://github.com/pedronaugusto/gantry`, then obtain the `gantry` module through
`b.dependency` and add it to your executable's imports. Forward your target and optimize
settings.

## Usage

[examples/usage.zig](examples/usage.zig) supplies `read` from an in-memory file store.
Its reader callback is `read(context, path, scratch_allocator) !?[]const u8`.

<!-- BEGIN GENERATED ci/readme_usage.sh -->
```zig
const gantry = @import("gantry");

const paths = &.{ "src/main.zig", "src/store.zig", "src/model.zig" };
var graph = try gantry.scan(gpa, paths, {}, read, .{});
defer graph.deinit();

for (graph.edges()) |edge| {
    std.debug.print("{s} -> {s} ({d})\n", .{ edge.from, edge.to, edge.count });
}
var analysis = try graph.analyze(gpa);
defer analysis.deinit();
for (analysis.layers()) |layer| {
    std.debug.print("{s}: depth {d}\n", .{ layer.path, layer.depth });
}

const findings = try graph.check(gpa, .{
    .nothing_imports = &.{.{ .name = "entry files", .to = "**/main.zig" }},
    .no_cycles = "no cycles",
});
defer gpa.free(findings);
for (findings) |finding| std.debug.print("{s}: {s}\n", .{ finding.rule, @tagName(finding.reason) });
```
<!-- END GENERATED -->

## Design

The library uses only `std`. Scan scratch storage is released between files; reader
bytes need to survive processing until the next read. Graph, analysis, import and path
results retain their allocator and own their storage. Move these handles and call
`deinit` once; their slices last until release. Analysis and aggregation results are
independent of the original graph. Rule findings borrow the graph, rule names and
required-path strings; keep those alive and free the findings with `rules.free`, which
also frees the chains of transitive findings (`gpa.free` alone suffices when no rule is
transitive).

Preprocessing copies names directly into returned references; recovery records stay in the scan workspace, and file scratch is released after each file.

Paths are relative to one logical root and use `/` on every host. Normalization resolves
`.` and `..` within that root, merges duplicate paths and refuses absolute paths,
drives, backslashes, NUL and traversal above the root. Comparisons are byte and case
exact. The reader receives normalized paths; it should return stable contents throughout
a scan because resolution can read a file more than once.

A null reader result records the path in `graph.unread()`. Reader, manifest and
configuration errors abort without a partial graph. `scanWithDiagnostic` additionally
retains the failed path, phase, optional byte offset and original cause in a
caller-owned `ScanDiagnostic`. Reporting preserves the cause even if copying the path
fails.

<!-- BEGIN GENERATED ci/readme_usage.sh diagnostic -->
```zig
const gantry = @import("gantry");

var diagnostic = gantry.ScanDiagnostic.init(gpa);
defer diagnostic.deinit();
return gantry.scanWithDiagnostic(gpa, paths, {}, read, .{}, &diagnostic) catch |cause| {
    if (diagnostic.failure) |failure| {
        std.debug.print("{s}: {s}: {s}\n", .{
            failure.path orelse "<scan>",
            @tagName(failure.phase),
            @errorName(failure.cause),
        });
    }
    return cause;
};
```
<!-- END GENERATED -->

## Recovery

Import recovery uses byte lexers for Zig, C/C++, JavaScript/TypeScript, Python, Go,
Rust, Nim and Java. Resolution stays within selected files. Zig named modules and C include roots are
caller inputs; JS/TS aliases come from selected local configs; Python initializer and
literal star-reexport handling are selectable; Go uses selected module/workspace routing
and optional target constraints. Rust resolves file modules and crate-relative use paths
without macro expansion; a path rooted at a crate's name (`use serde::X`, `extern crate
libc`, `serde_json::to_string` in code or an attribute) is an unresolved reference, once
per file, unless a `use`, module or alias of the file brought the name in.

Rust test classification propagates through file modules; owned recovered operands let it share each available source read with import resolution.

Go workspace routing keeps local module edges, and recorded build constraints let caller targets select files; constraint parsing and imports share a source read and token stream.

Python literal `__all__` reexports retain selected implementation edges; owned recovered operands let export indexing and imports share a source read and token stream.

Nim `import`, `include` and `from` modules resolve as the compiler finds them: beside the
importing file, then on the literal `--path` entries of selected `nim.cfg`, `config.nims`
and project configs above it, nearest and latest first. `std/` names stay with the standard
library and `pkg/` names use only search paths. Every `when` branch counts, and a path with
a `$` substitution is not read.

Java imports resolve through the `package` each selected file declares, wherever the file
sits: `a.b.C` is `C.java` in package `a.b`, a nested or static member falls back to its
enclosing type's file, and `a.b.*` is an edge to every file of the package. That
over-approximates: the importer uses only some of those types, and only symbol-level
dependencies could narrow it. A type that several selected files declare resolves to each
of them. Types of the importer's own package and
fully qualified names need no import, so they give no edge. Sources are read once for
their package and imports. `Class.forName` and `loadClass` calls are unsupported.

`graph.references()` keeps import spellings, offsets, kinds and resolution status.
Detectable unsupported constructs appear in `graph.unsupported()` without guessed edges.
`strict_imports` refuses the first such construct with `UnsupportedImport`, even when
import edges are disabled. An unresolved supported literal is a reference, not an
unsupported construct. Loader aliases, generated imports and other runtime semantics can
remain undetected.

Import, type-only, dynamic and test edges are enabled by default; links and assets
require explicit kind selection. A TypeScript `import type`, `export type`, braces whose
every name is marked `type`, and `typeof import("x")` or `import("x").T` in a type give
`type_only` edges; any other `import("x")` call gives a `dynamic` edge, and a test file's
import a `test` edge whatever its form. `kindsOf(path)` says which kinds a scan reads from a file, by its name. Markdown recovery handles inline relative links and wiki links while
excluding fenced code and comments. Asset recovery matches path tokens in supported text
files. Manifest declarations from `build.zig.zon`, `package.json`, `Cargo.toml`,
`go.mod`, `pyproject.toml`, `pom.xml`, `build.gradle`, `build.gradle.kts`
(`manifests.names`) and `.nimble` files (`manifests.extensions`) remain separate from file
edges. A Maven `${property}` resolves through the same file's literal properties and
project coordinates, and an `<optional>` dependency is optional unless its scope is `test`. Gradle declarations are read when literal. A declaration a reader
cannot read, such as a Gradle version catalog entry, an interpolated coordinate or a
`requires` with a computed argument, declares nothing and appears in `graph.unsupported()`.
A declaration's `scope()` is runtime, development, optional or build, read from its
manifest's own groups; a `go.mod` requirement marked `// indirect` is in group
`indirect`. Its `origin` is registry, local, remote or workspace, taken from
the key or form that named its `source` (a ZON `.path` is local however it is written),
and `revision()` is a pin the remote source spells in its own text. The TOML and Go
declaration readers do not validate their entire formats.

## Graphs and rules

Edges point from an importer to its dependency and count reference occurrences.
Construction sorts and coalesces them; caller edges go through `Graph.fromEdges`.
Aggregation keeps self edges within directories. Analysis collapses strongly connected
components for layer calculation; depth is the longest path from a root, and each cycle
has one closed witness path. An isolated file has depth zero.

An analysis also answers queries over the graph it was made from: `direct(path,
direction)` lists what a file depends on or what depends on it, `reach(starts,
direction)` everything a chain of one edge or more leads to or from, `affected(changed)`
the changed files and everything that depends on one of them (a path the analysis does
not hold, such as a deleted file, is skipped), and `chain(from, to)` the shortest chain
between two files. Results are path-ordered slices the caller frees; their paths belong to
the analysis. A query holds one mark and one queue entry per node, whatever the closure.
To follow some edge kinds only, analyse a graph of those edges (`Analysis.init`).

`coupling()` gives each node's distinct dependents (`fan_in`, Ca) and dependencies
(`fan_out`, Ce), with `instability()` Ce / (Ca + Ce), 0 for a node with neither.
`directoryCoupling()` does the same for every directory above a node: a dependency
counts for each directory holding one end and not the other, as dependency-cruiser's
folder metrics count it. Edges of several kinds between two files are one dependency.

Rules restrict ordered layers, source/target patterns, raw references, required paths
and cycles. Exceptions apply to a named restriction. Path patterns use `*` and `?`
within a component and `**` across components. Every matching restriction reports in
rule order. These rules operate on the recovered graph.

A `transitive` forbidden rule restricts chains of any length, as import-linter's
forbidden contracts and dependency-cruiser's `reachable` rules do: each file matching
`from` from which edges lead, through any files, to a file matching `to` reports the
shortest such chain in `chain`, from that file to the first target it meets, choosing
the first path at each position among chains of that length. An allowance for the rule
takes its edges out of the chains, so `.{ .rule = "ui to db", .kind = .type_only }` lets
type-only chains through. Transitive ordered layers work as import-linter's layers
contract: a file no layer names has no layer, chains pass through it, and each layered
file reports the shortest chain through unlayered files to each higher layer it reaches.

A dependency rule joins each unresolved import to the manifests that govern its file:
those of its ecosystem in the nearest directory at or above it (`package.json`,
`pyproject.toml`, `Cargo.toml`, `go.mod`, `build.zig.zon`, a `.nimble`, `pom.xml`,
`build.gradle`). An import names its package by the ecosystem's own rule: an npm name or
`@scope/name`, a Python top-level module (case and `-_.` runs aside, as PEP 503 compares),
a Rust crate (`-` as `_`), the longest Go module path that holds it, a Zig module, a Nim
package (after `pkg/`), and for Java the declarations whose group holds the import's
package. The language's own modules are no packages: Node builtins and `node:` names,
Python's standard library, Rust's `std`, `core`, `alloc`, `proc_macro` and `test`, Go
paths with no dot in their first element, Zig's `std`, `builtin` and `root`, Nim's
standard modules and `std/`, and the JDK's packages. Findings are `undeclared` imports,
with the reference, the package and the manifest, once per file and package, and
`unused` declarations of the rule's scopes (runtime by default), with the declaration,
for manifests that govern a source file the rule covers. A Go `indirect` requirement,
Nimble's `nim` and a Gradle or Maven workspace project are never unused. An import whose
package goes by another name, such as Python's `yaml` from `PyYAML` or Java's
`com.google.common` from Guava, needs a `names` entry; `ignore` takes package names.
The graph must be scanned with manifests (`error.UnscannedManifests` otherwise).

A reachable rule names entry files by pattern and reports every file matching `files`
that no chain from an entry reaches (`unreached`), as madge's orphans and
dependency-cruiser's `no-orphans` and `reachable: false` rules do; a file with no edges
at all is unreached unless it is an entry. `kind` restricts the edges chains follow.

A token rule names an identifier, or a string literal's value after its escapes, that
only its owners' files may spell: `.{ .name = "console", .token = "CreateFileW", .owners =
&.{"src/os/**"} }`. `*` in a token matches any bytes and `?` one byte. Pass the same rules
in `Options.tokens` and `Rules.tokens`: the scan records their occurrences from the token
streams it lexes for imports (`graph.tokens()`, with path, line and byte column), and
`check` reports those outside the owners, or `error.UnscannedToken` for a rule the scan
did not record. Comments, character literals, numbers, raw strings and multi-line strings
never match.

## Scope

- It does not discover a repository, apply gitignore rules or select files for the caller.
- It does not invoke a compiler, preprocess source or evaluate build scripts, macros, Nim
  `when` conditions or config substitutions.
- It does not construct symbol, call or runtime dependency graphs.
- It does not install packages, follow Maven parents or Gradle catalogs, or solve
  transitive external versions.
- It does not implement complete language, CommonMark, TOML or asset-format grammars.
- It does not render a graph or provide a command-line linter.

<!-- performance: quiet pass -->

## Testing

Local build scripts clear `.zig-cache/{o,h,z,tmp}` above the measured cap in `ci/cache.sh`; run `sh ci/cache.sh` before direct Zig builds (only a rebuild is lost).

`zig build test` runs the suite and usage example in Debug by default. Fixtures cover
lexical exclusions, resolvers, manifests, diagnostics, strict imports and rules.
Generated graphs are checked against independent reachability and depth calculations;
allocation-failure tests check cleanup. Every lexer and every manifest and config reader
has a `std.testing.fuzz` property (no panic or leak, only documented errors, output bounded
by the input, the same result twice): `zig build test` runs their seeds and `zig build test
--fuzz` searches from them. `zig build examples` runs the example
separately; `zig build check` compiles the tests only. CI also runs `ci/check-docs.sh`.

[CI](.github/workflows/ci.yml) runs tests and the example in Debug and ReleaseSafe on
`ubuntu-latest`, `macos-latest` and `windows-latest`, plus ReleaseFast on Ubuntu.
ReleaseSmall compiles the tests, example and library without running them on Ubuntu.
Source checks run formatting and cast checks on Ubuntu. There is no ThreadSanitizer job.

Compile-only jobs use the default `zig build` for `x86_64-linux-gnu`,
`aarch64-linux-gnu`, `x86_64-linux-musl`, `x86_64-windows-gnu`, `x86_64-windows-msvc`,
`aarch64-windows-gnu`, `x86_64-macos`, `aarch64-macos`, `x86_64-freebsd` and
`x86_64-netbsd`.

## Licence

MIT. See [LICENSE](LICENSE).
