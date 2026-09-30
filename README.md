# gantry

[![CI](https://github.com/pedronaugusto/gantry/actions/workflows/ci.yml/badge.svg)](https://github.com/pedronaugusto/gantry/actions/workflows/ci.yml)

gantry reads a codebase's files and says what depends on what. It recovers
imports in Zig, C/C++, JavaScript/TypeScript, Python, Go and Rust, Markdown
links, and asset paths. One graph records the file edges, directory edges,
manifest dependencies, layers and cycles. Rules check the boundaries a
caller gives it.

The files are the caller's choice. Pass paths and a reader, or use an
already-open `std.Io.Dir`. There is no git, ignore policy, subprocess or
background thread, and no dependency beyond `std`.

## Usage

The block below comes from [`examples/usage.zig`](examples/usage.zig), which
`zig build examples` builds and runs. `read` in that example stands in for
the caller's file store; its signature is described below.

<!-- BEGIN GENERATED ci/readme_usage.sh -->
```zig
const gantry = @import("gantry");

const paths = &.{ "src/main.zig", "src/store.zig", "src/model.zig" };
var graph = try gantry.scan(gpa, paths, {}, read, .{});
defer graph.deinit();

for (graph.edges) |edge| {
    std.debug.print("{s} -> {s} ({d})\n", .{ edge.from, edge.to, edge.count });
}
var analysis = try graph.analyze(gpa);
defer analysis.deinit();
for (analysis.layers) |layer| {
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

## Install

```
zig fetch --save git+https://github.com/pedronaugusto/gantry
```

```zig
const dep = b.dependency("gantry", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("gantry", dep.module("gantry"));
```

The repository is private during review. Fetching it currently needs access.

## The API

| Declaration | What it does |
|---|---|
| `scan(gpa, paths, context, read, options)` | Reads the selected files and returns an owned `Graph`. |
| `Graph.init(gpa, paths)` | An edgeless graph with these nodes. |
| `Graph.fromEdges(gpa, paths, edges)` | Copies, validates, sorts and coalesces caller edges. |
| `graph.aggregate(gpa, depth)` | An independent graph of directories, including isolated ones. |
| `graph.analyze(gpa)` | An independent `Analysis`: `layers`, `components`, `cycles`. |
| `graph.check(gpa, rules)` | Every violation, with its rule name and edge, reference or missing path. Free the returned slice with `gpa.free`. |
| `imports(gpa, language, bytes)` | An owned `Imports` with raw `items`, including Zig member references. No resolution. |
| `DirReader{ .io, .dir, .limit }.read` | The reader over a caller-owned directory, with a caller-chosen byte limit. |
| `walk(gpa, io, dir, context, keep)` | An owned `Paths`; `keep(context, path, kind)` can prune directories. Symlinks and other special entries are skipped. |
| `languageOf(path)` | The language selected by the file extension, or null. |
| `manifests.parse(arena, path, bytes)` | Low-level extraction of declarations in one supported manifest. Uses an arena; slices borrow bytes or that arena. |
| `rules.matches(pattern, path)` | The same path glob matching used by rules. |

`Graph`, `Analysis`, `Imports` and `Paths` store their allocator. Call their
`deinit` once. Their slices and strings belong to them until then. An
analysis or aggregation survives the original graph. Rule findings borrow
the graph's paths and the caller's rule names, so both must outlive them.
Managed values may be moved but must not be copied and deinitialized twice.

The reader is a function
`read(context, path, scratch_allocator) !?[]const u8`. The bytes need only
survive processing that file, until the next read. Allocate them on the
scratch allocator or borrow from your file store. Scratch storage is reset
between files. Null records the path in `graph.unread`; an error aborts
without returning a partial graph. Unsupported files are graph nodes but
are not read. Manifests are read first so Go resolution has module paths.

Paths are relative to one logical repository root and use `/` on every
platform. `.` and `..` are normalized; absolute paths, drives, backslashes,
NUL and traversal above the root are refused. Duplicate normalized paths
become one node. Comparison is byte and case exact. The reader receives the
normalized spelling. Resolver roots and named-module paths use this same
convention.

`Options.kinds` defaults to `&.{.import}`; pass `.link`, `.asset`, or several
kinds explicitly. Manifest declarations are read by default. Turning them
off still reads selected `go.mod` files for import resolution. Gantry never
adds files the caller did not select.

## The graph

An `Edge` has `from`, `to`, `kind` and `count`. Direction is from the file
that names a dependency to the file it names. Counts are reference
occurrences: repeated imports count again, while a single Python statement
reaching an initializer by several paths counts it once. Member accesses do
not add a second import edge. Kinds stay separate during aggregation.

`graph.references` retains literal imports, their byte offsets, whether they
resolved, and Zig member access. An unresolved reference may name an external
package, a missing file, or syntax whose resolution gantry does not implement.
It is not automatically a declared external dependency.

`graph.dependencies` contains manifest declarations, separately: manifest,
name, requirement, source, group. A declaration in two groups stays as two
records. Registry versions remain requirements; URLs and local paths remain
sources. There is no installation, version solving, or transitive closure of
external packages.

Aggregation depth 0 puts every file in `.`; depth 1 uses the first directory
component; larger depths keep up to that many components. Root files stay in
`.`. Self edges are retained, including the edges within a directory. Analyzing
an aggregated graph therefore treats a directory self edge as a cycle.

An analysis uses iterative strongly connected components. Every SCC becomes
one node for layer calculation. A root component has depth 0; every other
component has the **longest** path depth from a root, following dependency
edges. All members of a cycle share a depth. Isolated files have depth 0.
Each cycle has sorted `members` and one actual closed `path` through its
edges, including self imports. This is not an enumeration of every loop.

Nodes, edges, references and declarations are sorted independently of input
order. Components and cycles are ordered by their first member; witnesses
start there and choose the first outgoing edge within the component, then
a breadth-first return path. Graph algorithms use heap stacks, so a long
chain does not consume the machine's call stack.

## Imports

Each language has its own module under `src/lang/`, using hand-written byte
lexing. Comments, quoted text and character literals do not contribute import
keywords. Resolution is against the selected path set.

| Language | Recovered syntax and resolution | Limits |
|---|---|---|
| Zig | Literal `@import`, with whitespace, comments and decoded escapes. Relative `.zig` paths; named imports through `Options.named_modules`, optionally scoped by `from` glob. Direct `@import("pkg").member` and `const`/`var` bindings followed by `.member` are retained for rules. | No build graph evaluation, computed strings, binding scope or chains of aliases. Without a named-module mapping a package stays unresolved. |
| C/C++ | Line-start `#include "..."` and `<...>`, with comments removed. The importing directory, then `Options.include_roots` in order. | No preprocessing, conditional evaluation, macro includes, compiler search path or C++ module imports. Both include forms use the stated search order. Splicing within an identifier is unsupported. |
| JS/TS | ESM side effects, `import ... from`, type imports, re-exports, literal `require()` and dynamic `import()`, including template expressions. Relative exact paths, then TS/JS extensions and directory indexes; emitted `.js` paths can fall back to `.ts`/`.tsx`. | No AMD, package exports, package index metadata, tsconfig aliases, binding scope or computed specifiers. Regex/division uses lexical context, not a full JS parser; JSX text and grammar-ambiguous regex contexts are outside the supported syntax. Template text does not count. |
| Python | Absolute and relative `import`/`from`, aliases, lists, parenthesized lists and continued lines. Searches `Options.python_roots` (repository root by default); relative dots stay inside the source root. Selected package initializers are included. | No interpreter, `sys.path` changes, `importlib`, implicit legacy sibling search or runtime imports. `from package import attribute` resolves the package and a child module only if selected; gantry cannot tell which name is an attribute at runtime. |
| Go | Single and grouped imports, aliases, dot/blank imports, ordinary and raw string literals. The nearest selected `go.mod` establishes the exact module path; an import expands to all selected `.go` files in that package. Nested modules are boundaries. | No `go.work`, replacements, vendoring, build constraints, cgo or platform selection. Test files participate if selected. No suffix guessing without `go.mod`. |
| Rust | External `mod name;`, `use crate::`, `super::`, `self::`, aliases and nested use trees. File modules use `name.rs` or `name/mod.rs`; child modules of `foo.rs` live under `foo/`. Uses resolve the longest selected module prefix. | No macro expansion, `cfg` evaluation, `#[path]`, inline-module scope or semantic name resolution. The nearest `src` directory is the crate root; nonstandard roots need caller edges. External crate uses are not file edges. |

JS resolution tries exact spelling first, then `.ts`, `.tsx`, `.js`, `.jsx`,
`.mjs`, `.mts`, `.cjs`, `.cts`, then `index.ts`, `index.tsx`, `index.js`,
`index.jsx`, `index.mjs`, `index.cjs`. This is a documented convention, not a
promise to reproduce every loader. C/C++ also recognizes Objective-C file
extensions `.m` and `.mm`.

## Links and assets

Markdown recovery reads `.md` files. It recognizes `[[wiki]]`, headings and
aliases, and inline relative Markdown links and images, with optional titles,
angle-delimited destinations and escaped parentheses. It skips fenced code,
inline code, HTML comments and escaped openings. Relative links resolve beside
the page; wiki links try beside the page, then the root, then a unique basename
without `.md`. An ambiguous basename stays unresolved. Self links and URLs are
ignored. Reference-style links, HTML anchors, percent-decoding, indented code
blocks and the full CommonMark grammar are not implemented.

Asset recovery reads common text/data extensions and matches complete path
tokens, first from the root and then beside the file. Tokens contain letters,
digits, non-ASCII bytes and `./_-@`. A path embedded in a longer token does not
match. Self references are ignored. This is a path recoverer, not an HTML,
CSS or JSON parser: it reads comments too and does not decode escapes, spaces
in filenames or URLs. It uses indexed lookups rather than searching every
source byte for every repository path.

## Manifests

All selected manifests are read, including those below the repository root.

| Manifest | Declarations |
|---|---|
| `build.zig.zon` | `.dependencies`, quoted names, URLs, paths and hashes. Comments and strings containing braces do not change the block. |
| `package.json` | Dependencies, dev, peer and optional dependencies, with their string requirements. Uses `std.json`. |
| `Cargo.toml` | Normal, dev, build, workspace and target dependency tables, inline dependency tables and separate per-dependency tables; versions, git, path and `workspace = true`. |
| `go.mod` | `require` lines and blocks; full module paths, versions and sources. |
| `pyproject.toml` | PEP 621 project and optional requirements, string dependency groups, and Poetry dependency groups; extras, markers and direct URLs remain in the requirement. |

The ZON, TOML and Go readers extract declarations; they are not full format
validators. JSON and malformed dependency shapes are errors. General TOML
multiline strings, dotted dependency keys, dependency-group inclusion,
workspace inheritance resolution, Go replacements and lockfiles are outside
scope. Partial declarations are not returned after an extraction error.

## Rules

`rules.Rules` is data. `ordered` contains named sets of layers, lowest first.
Each layer has path patterns; the first match wins, and an unspecified file
defaults to layer 0. An edge to a higher layer is a violation. Computed graph
depths and caller-declared rule layers are separate things.

`forbidden` matches source and target patterns, optionally an edge kind.
`nothing_imports` matches a target; it can keep entry files imported by nobody.
`allowed` names the restriction it exempts, plus source and target patterns,
so a test root can import an entry file without waiving the other rules.

`references` restricts raw import names, optionally just unresolved ones or a
particular Zig member. Raw names match the whole name, including package path
components. A suffix filter and relative-path normalization can restrict
imports of missing files too, such as allowing only `proto/*.zig` as proto
siblings. Exceptions can name permitted targets or importers.
This expresses package ownership and an API member forbidden to one tree.
`required` names exact paths that must exist, for layer tables with named
modules. `no_cycles` names the rule that rejects every cyclic SCC.

Patterns use `*` and `?` within a path component, and `**` as a complete
component across zero or more directories. A pattern without `/` matches the
basename. Matching is case exact. Findings are returned in rule order, then
graph order; every matching restriction reports, even when another also
forbids the edge. Cycles report one witness edge per component, and missing
paths report the path, with no invented edge.

## Other tools

| Tool | Where it goes further |
|---|---|
| [madge](https://github.com/pahen/madge), [dependency-cruiser](https://github.com/sverweij/dependency-cruiser) | JS ecosystem resolution, more module forms, configuration and visual reports; dependency-cruiser also supplies a larger rule vocabulary. |
| [pydeps](https://github.com/thebjorn/pydeps), [import-linter](https://import-linter.readthedocs.io/en/stable/) | Python-specific import graphs and contracts, including an installed package's import environment. |
| [`go list`](https://pkg.go.dev/cmd/go#hdr-List_packages_or_modules), [goda](https://github.com/loov/goda) | The Go toolchain's package/module selection and dependency graph, including build constraints. |
| [cargo-modules](https://github.com/regexident/cargo-modules) | Rust's semantic module and item structure through rust-analyzer. |
| [deptrac](https://deptrac.github.io/deptrac/), [ArchUnit](https://www.archunit.org/userguide/html/000_Index.html) | PHP and Java architecture checks. Gantry does not parse those languages or inspect bytecode. |

gantry is an embeddable Zig library over caller-supplied files, covering several
languages with the same graph and rules. It does not claim the compiler's view
of a program. Use a language tool when that view is what the check needs;
`Graph.fromEdges` can hold edges recovered elsewhere.

## Performance

Measurements live on the `bench` branch; the harness is not part of `main` or
the package. Run its mixed-language synthetic corpus in ReleaseFast on one
calling thread. Scan time includes path indexing, lexing, resolution and
manifest extraction. Listing and analysis are reported separately.

Apple M3 Max, Zig 0.16.0, ReleaseFast, 30,002 files across the six languages,
30.7 MB of source, 75,000 edges, 2026-09-30:

| Operation | Measured |
|---|---|
| Path listing | 83 ms |
| First filesystem scan | 691 ms |
| Subsequent filesystem scans | 573–674 ms |
| Scan with caller-held bytes | 32–34 ms |
| SCCs, witnesses and longest depths | 5.6–6.1 ms |
| Directory aggregation | 5.0–5.2 ms |

The files were just written, about 1 kB each, mostly comments with import
and string decoys. This measures that corpus on local storage, not cold-disk
latency or arbitrary loader semantics. Memory loading and corpus generation
are outside the timings. There is no absolute-time test.

## Scope

- Selected source references and declared direct dependencies, not symbol,
  runtime, call or transitive external dependency graphs.
- No repository discovery policy, git access, compiler, package manager,
  regex engine, rendering, command-line linter or background work.
- Syntax outside the language rules above can remain unresolved or be missed.
  Rules validate the recovered graph, not the entirety of a compiled program.

## Testing

`zig build test` runs the suite and the usage example. It covers lexical
exclusions, each resolver, the reference fixtures, manifests, rules,
ordering and ownership. Generated graphs are checked against transitive
reachability and an independent depth calculation. A 20,000-node chain
checks iterative traversal; allocation failures check cleanup. Filesystem
tests use temporary directories under `std.testing`; no personal configuration
is read or written.

CI runs Linux, macOS and Windows in Debug, ReleaseSafe, ReleaseFast and
ReleaseSmall, checks formatting, casts and this generated usage block, and
compiles Linux, Windows, macOS and BSD targets. Select tests with
`zig build test -Dtest-filter=fixture:`. `zig build check` compiles without running.

## Requirements

Zig 0.16.0.

## Licence

MIT. See [LICENSE](LICENSE).
