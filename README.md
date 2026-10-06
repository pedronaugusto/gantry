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
Its reader callback is `read(scratch_allocator, context, path) !?[]const u8`.

<!-- BEGIN GENERATED zig build docs -- usage -->
```zig
const gantry = @import("gantry");

const paths = &.{ "src/main.zig", "src/store.zig", "src/model.zig" };
var graph = try gantry.scan(gpa, paths, {}, read, .{});
defer graph.deinit();

for (graph.edges()) |edge| {
    std.log.info("{s} -> {s} ({d})", .{ edge.from, edge.to, edge.count });
}
var analysis = try graph.analyze(gpa);
defer analysis.deinit();
for (analysis.layers()) |layer| {
    std.log.info("{s}: depth {d}", .{ layer.path, layer.depth });
}

// A file the scan could not read as its format is a record, not an error.
for (graph.invalid()) |file| {
    std.log.info("{s}: {s}", .{ file.path, @errorName(file.cause) });
}

var findings = try graph.check(gpa, .{
    .nothing_imports = &.{.{ .name = "entry files", .to = "**/main.zig" }},
    .no_cycles = "no cycles",
});
defer findings.deinit();
for (findings.items()) |finding| std.log.info("{s}: {s}", .{ finding.rule, @tagName(finding.reason) });
```
<!-- END GENERATED -->

## Design

The library uses only `std`. Scan scratch storage is released between files; reader
bytes need to survive processing until the next read. Graph, analysis, import and path
results retain their allocator and own their storage. Move these handles and call
`deinit` once; their slices last until release. Analysis and aggregation results are
independent of the original graph. `check` returns an owned `Findings` whose `items()`
point into the graph's edges, references, tokens and declarations and borrow rule names
and required-path strings; keep those alive until `deinit`, which also frees the chains
of transitive findings.

Preprocessing copies names directly into returned references; recovery records stay in the scan workspace, and file scratch is released after each file.

Paths are relative to one logical root and use `/` on every host. Normalization resolves
`.` and `..` within that root, merges duplicate paths and refuses absolute paths, a
drive (a letter and `:` starting the path), backslashes, NUL and traversal above the root;
a colon elsewhere is an ordinary byte. `walk` skips a name normalization refuses. Comparisons are byte and case
exact. The reader receives normalized paths; it should return stable contents throughout
a scan because resolution can read a file more than once.

A null reader result records the path in `graph.unread()`. A selected file whose bytes
are not valid for the format it is read as (a manifest or config that does not parse, a
literal with an undefined escape, a Go `//go:build` line that is not a constraint) is a
record in `graph.invalid()`, with its path, phase and `FileError` cause, and gives the
scan nothing from that phase: a Go file with a bad constraint is in no package, a broken
config is as if absent, and the scan goes on. A caller that wants such a scan to fail
checks that list. A scan fails, with no partial graph, only with a `ScanError` (a selected
path normalization refuses, `strict_imports` and an unsupported construct, a count
overflow, memory) or one of the reader's own errors. `scanWithDiagnostic` additionally
retains the failed path, phase, optional byte offset and original cause in a
caller-owned `ScanDiagnostic`. Reporting preserves the cause even if copying the path
fails. A leading UTF-8 byte order mark is no part of a file.

<!-- BEGIN GENERATED zig build docs -- diagnostic -->
```zig
const gantry = @import("gantry");

var diagnostic = gantry.ScanDiagnostic.init(gpa);
defer diagnostic.deinit();
return gantry.scanWithDiagnostic(gpa, paths, {}, read, .{}, &diagnostic) catch |cause| {
    if (diagnostic.failure) |failure| {
        std.log.info("{s}: {s}: {s}", .{
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
without macro expansion. A `use` path rooted at a file module the current module
declares (`mod util; use util::Thing;`) resolves to it, as rustc's 2018 paths do; beside an
`extern crate` of that name it gives no edge, since rustc rejects both. A path rooted at a crate's name (`use serde::X`, `extern crate
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
`type_only` edges; any other `import("x")` call gives a `dynamic` edge. A Python import
under `if TYPE_CHECKING:` (or `if name.TYPE_CHECKING:`), nested blocks included, is
`type_only`, as import-linter's `exclude_type_checking_imports` reads it, except that the
`else` branch runs and stays `import` (Grimp drops it too).
`importlib.import_module` and `__import__` with literal names give `dynamic` edges, a
relative name resolving against `import_module`'s literal package; other arguments are
unsupported. A test file's import is a `test` edge whatever its form. `kindsOf(path)` says which kinds a scan reads from a file, by its name. Markdown recovery handles inline relative links and one-line wiki links while
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

A dependency rule joins each import to the manifests that govern its file:
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
with the reference, the package and the manifest, once per file and package (an import
that resolves to a selected file is never undeclared, but it does use its declaration, as a
Go `replace` or a Zig path module does), and
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

## Reports

`gantry.report` writes text for the tools that lay out, draw and annotate, to a
`*std.Io.Writer`. Output is the same for the same graph, options and findings.

| Call | Writes |
|---|---|
| `report.dot(gpa, w, graph, options)` | A Graphviz digraph |
| `report.mermaid(gpa, w, graph, options)` | A Mermaid flowchart with the same nodes, edges and clusters |
| `report.json(w, graph, findings)` | Nodes, edges and findings as one JSON object |
| `report.sarif(gpa, w, findings, options)` | A SARIF 2.1.0 log for GitHub code scanning and other SARIF readers |
| `report.sarifWithSource(gpa, w, findings, context, read, options)` | The same, with lines and columns read from the sources |

Drawings list nodes in path order, then edges in the graph's order. `cluster` is
`.none`, `.directory` (nested boxes, nodes labelled with their last component) or
`.layer` (one box per `rules.Layer` in `layers`, a node in the first that matches it).
Edge kinds are styles: `import` solid, `type_only` dashed, `dynamic` dotted, `test` with a
hollow head, `link` and `asset` broken with their own heads; Mermaid labels every kind but
`import`. The findings in `options.findings` are drawn red: the nodes they name, their
edges and every edge along a chain. For directories as nodes, draw `graph.aggregate(depth)`.
Mermaid refuses more than 500 edges by default.

JSON is `{"format": "gantry", "version": 1, "nodes", "edges", "findings"}`: each node
`{"path"}`, each edge `{"from", "to", "kind", "count"}`, and each finding its `rule` and
`reason` with only the fields that finding has (`edge`, `reference`, `token`, `path`,
`dependency`, `package`, `chain`). Offsets are bytes. `version` changes only when a
field changes meaning or goes away.

SARIF lists each rule name once as a rule id and each finding as an `error` result at the
file it is about, under `uri_prefix`. A token finding has its line; `sarifWithSource`
reads each file a reference or token finding names once, through the same reader `scan`
takes, for a line and a column in code points. Edge findings are about the importing file:
an edge keeps no offset.

DOT quotes escape `"` and `\`, write a newline as `\n` and other control bytes and bytes
that are not UTF-8 as `\xNN`, so distinct paths stay distinct IDs. Mermaid nodes are numbered and labels use entity
codes. JSON writes a byte that is not UTF-8 as U+FFFD; SARIF URIs percent-encode
every byte outside the unreserved set and `/`.

## Scope

- It does not discover a repository, apply gitignore rules or select files for the caller.
- It does not invoke a compiler, preprocess source or evaluate build scripts, macros, Nim
  `when` conditions or config substitutions.
- It does not construct symbol, call or runtime dependency graphs.
- It does not install packages, follow Maven parents or Gradle catalogs, or solve
  transitive external versions.
- It does not implement complete language, CommonMark, TOML or asset-format grammars.
- It does not lay out or render a graph, or provide a command-line linter.

<!-- performance: quiet pass -->

## Testing

Local build scripts clear `.zig-cache/{o,h,z,tmp}` above the measured cap in `ci/cache.sh`; run `sh ci/cache.sh` before direct Zig builds (only a rebuild is lost).

`zig build test` runs the suite and usage example in Debug by default. Fixtures cover
lexical exclusions, resolvers, manifests, diagnostics, strict imports and rules.
Generated graphs are checked against independent reachability, depth, closure,
shortest-chain, coupling and nearest-target calculations; allocation-failure tests check
cleanup, and a 50,000-file graph bounds a query's memory. Every lexer, every manifest and
config reader, and the package names dependency rules read from import spellings have a
`std.testing.fuzz` property (no panic or leak, only documented errors, output bounded
by the input, the same result twice): `zig build test` runs their seeds and `zig build test
--fuzz` searches from them. `zig build examples` runs the example
separately; `zig build check` compiles the tests only. CI also runs `zig build lint`.
Reports are compared with golden files in `src/testing/golden`, which CI reads with Graphviz's
`dot`, Mermaid's CLI and the SARIF 2.1.0 schema.

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
