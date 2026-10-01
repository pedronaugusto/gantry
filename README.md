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

## Install

```
zig fetch --save git+https://github.com/pedronaugusto/gantry
```

```zig
const dep = b.dependency("gantry", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("gantry", dep.module("gantry"));
```

## The API

| Declaration | What it does |
|---|---|
| `scan(gpa, paths, context, read, options)` | Reads the selected files and returns an owned `Graph`. |
| `Graph.init(gpa, paths)` | An edgeless graph with these nodes. |
| `Graph.fromEdges(gpa, paths, edges)` | Copies, validates, sorts and coalesces caller edges. |
| `graph.aggregate(gpa, depth)` | An independent graph of directories, including isolated ones. |
| `graph.analyze(gpa)` | An independent `Analysis`: `layers()`, `components()`, `cycles()`. |
| `Analysis.init(gpa, paths, edges)` | An independent analysis using `Graph.fromEdges` validation and ordering. |
| `graph.check(gpa, rules)` | Every violation, with its rule name and edge, reference or missing path. Free the returned slice with `gpa.free`. |
| `imports(gpa, language, bytes)` | An owned `Imports` with raw `items()`, including Zig member references. No resolution. |
| `DirReader{ .io, .dir, .limit }.read` | The reader over a caller-owned directory, with a caller-chosen byte limit. |
| `walk(gpa, io, dir, context, keep)` | An owned `Paths`; `keep(context, path, kind)` can prune directories. Symlinks and other special entries are skipped. |
| `languageOf(path)` | The language selected by the file extension, or null. |
| `manifests.parse(arena, path, bytes)` | Low-level extraction of declarations in one supported manifest. Uses an arena; slices borrow bytes or that arena. |
| `rules.matches(pattern, path)` | The same path glob matching used by rules. |

`Graph`, `Analysis`, `Imports` and `Paths` are opaque value handles that own
their storage and allocator. Constructors are the only way to create them.
Call their `deinit` once. Read results through `Graph.paths()`, `edges()`,
`dependencies()`, `references()`, `unread()` and `goFiles()`, `Analysis.layers()`,
`components()` and `cycles()`, and `Imports.items()` or `Paths.items()`.
`Graph.contains(path)` tests exact normalized node membership without exposing
the index. Their slices and strings belong to them until then. An
analysis or aggregation survives the original graph. Rule findings borrow
graph storage and the caller's rule names and required-path strings
(`rules.required[].paths[]`). Keep the graph and those strings alive until
the findings are freed. Free only the returned slice.
Managed values may be moved but must not be copied and deinitialized twice.

The reader is a function
`read(context, path, scratch_allocator) !?[]const u8`. The bytes need only
survive processing that file, until the next read. Allocate them on the
scratch allocator or borrow from your file store. Scratch storage is reset
between files. Null records the path once in `graph.unread()`, across all scan
phases and kind selections; an error aborts
without returning a partial graph. Unsupported files are graph nodes but
are not read, except selected resolution configs. Manifests and configs are
read before code; Go constraints, Rust test modules and Python reexports may
require another read of a source file. Readers should return stable content
for the duration of a scan.

Paths are relative to one logical repository root and use `/` on every
platform. `.` and `..` are normalized; absolute paths, drives, backslashes,
NUL and traversal above the root are refused. Duplicate normalized paths
become one node. Comparison is byte and case exact. The reader receives the
normalized spelling. Resolver roots and named-module paths use this same
convention. An absolute reference cannot resolve beside its source file;
joining it to a source or config directory does not make it relative.

`Options.kinds` defaults to `&.{ .import, .@"test" }`; pass `&.{.import}`
for production edges, or include `.link` and `.asset` explicitly. Kind filters
select edges; raw references retain their source kind. Manifest declarations
are read by default. Turning them off still reads selected `go.mod`, `go.work`
and JS/TS configs for resolution. Select configs and their local `extends`
files along with code. Gantry never adds files the caller did not select.
Invalid or cyclic resolution configs abort the scan. A caller that needs a
structural view after an error can use `Graph.init(gpa, paths)`; that graph
makes no claim about recovered dependencies.

## The graph

An `Edge` has `from`, `to`, `kind` and `count`. Direction is from the file
that names a dependency to the file it names. Counts are reference
occurrences: repeated imports count again, while a single Python statement
reaching an initializer by several paths counts it once. Member accesses do
not add a second import edge. Kinds stay separate during aggregation.

`graph.references()` retains literal imports, their byte offsets, whether they
resolved, their source kind, and Zig member access. An unresolved reference may name an external
package, a missing file, or syntax whose resolution gantry does not implement.
It is not automatically a declared external dependency.

`graph.goFiles()` records each readable Go source's `path`, `package`, optional
`constraint` expression, optional suffix `os` and `arch`, and `selected` flag.
With no `Options.go_target`, every selected file participates and constraints
remain data. A supplied `GoTarget{ .os, .arch, .tags }` evaluates `!`, `&&`,
`||` and parentheses, OS aliases and `unix`, together with filename suffixes.
Inactive files stay in `graph.paths()` and metadata but contribute no references
or edges and are excluded from package expansion. Compiler, cgo, release and
custom tags must be supplied explicitly; gantry does not inspect the host.
Legacy `// +build`, implicit cgo file selection and architecture feature levels
are not inferred. Malformed evaluated constraints are errors.

`graph.dependencies()` contains manifest declarations, separately: manifest,
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

`Analysis.init` builds directly from caller paths and edges. It uses
`Graph.fromEdges` to normalize paths, merge duplicates, sort and coalesce
edges. Invalid or empty node paths return `InvalidPath`; absent endpoints
return `UnknownPath`; zero counts return `InvalidCount`; merged counts above
`usize` return `CountOverflow`. Both analysis entry points own their results.

## Imports

Each language has its own module under `src/lang/`, using hand-written byte
lexing. Comments, quoted text and character literals do not contribute import
keywords. Resolution is against the selected path set.

| Language | Recovered syntax and resolution | Limits |
|---|---|---|
| Zig | Literal `@import`, with whitespace, comments and decoded escapes. Relative `.zig` paths; named imports through `Options.named_modules`, optionally scoped by `from` glob. Direct `@import("pkg").member` and `const`/`var` bindings followed by `.member` are retained for rules. | No build graph evaluation, computed strings, binding scope or chains of aliases. Without a named-module mapping a package stays unresolved. |
| C/C++ | Line-start `#include "..."` and `<...>`, with comments removed. The importing directory, then `Options.include_roots` in order. | No preprocessing, conditional evaluation, macro includes, compiler search path or C++ module imports. Both include forms use the stated search order. Splicing within an identifier is unsupported. |
| JS/TS | ESM side effects, `import ... from`, type imports, reexports, literal `require()` and dynamic `import()`, including template expressions. Relative files, declarations, directory indexes, and selected `tsconfig.json`/`jsconfig.json` aliases. | No AMD, package exports/index metadata, installed-package resolution, binding scope or computed specifiers. Regex/division uses lexical context; JSX text and ambiguous regex contexts remain limits. Template text does not count. |
| Python | Absolute and relative `import`/`from`, aliases, lists, parentheses and continued lines. Searches `Options.python_roots` (repository root by default); relative dots stay inside the source root. Initializer edges and literal star reexports are selectable policies. | No interpreter, `sys.path` changes, `importlib`, implicit legacy sibling search or runtime imports. A selected child module may still be an attribute at runtime. Dynamic export lists and symbol reassignment are not evaluated. |
| Go | Single/grouped imports, aliases, dot/blank imports, ordinary/raw strings. Selected `go.mod` identities, local replacements and `go.work` use/replace routing. Imports expand to selected package files; nested modules are boundaries. Constraints and package names are retained. | No vendoring, module download, transitive version solving, cgo processing or compiler invocation. Version-specific replacements use selected requirements. Local paths must be relative and remain inside the repository. No module suffix guessing. |
| Rust | External `mod name;`, `use crate::`, `super::`, `self::`, aliases and nested use trees. File modules use `name.rs` or `name/mod.rs`; child modules of `foo.rs` live under `foo/`. Uses resolve the longest selected module prefix, including lexical inline-module scope. Explicit test guards and test modules carry a test kind. | No macro expansion, general `cfg` evaluation, `#[path]`, semantic definitions, reexports or type resolution. The nearest `src` directory is the crate root; nonstandard roots need caller edges. External crate uses are not file edges. |

JS/TS configs accept JSONC comments and trailing commas. Other syntax and
unterminated comments are errors. The root and `compilerOptions` must be
objects; `extends` must be a string or an array of strings, `baseUrl` a string,
and `paths` an object of string arrays. Wrong types return `InvalidConfig`.
The nearest selected
`tsconfig.json` (preferred over `jsconfig.json` in the same directory) supplies
`compilerOptions.baseUrl` and `paths`. Relative local `extends` chains and
arrays inherit options; child `paths` replace the inherited map. Cycles are
errors. Paths without `baseUrl` are relative to the config that declared them.
Exact patterns precede wildcard patterns; the longest wildcard prefix wins,
and targets are tried in order before the `baseUrl` fallback. Unselected,
external and package-based `extends` stay outside the selected universe.
Project include/exclude/files selection, rootDirs and project references are
caller policy, rather than compiler project discovery.

Resolution follows [TypeScript extension substitution](https://www.typescriptlang.org/docs/handbook/modules/reference#file-extension-substitution):
`.js`/`.jsx` tries `.ts`, `.tsx`, `.d.ts`, `.js`, `.jsx`; `.mjs` tries `.mts`,
`.d.mts`, `.mjs`; `.cjs` tries `.cts`, `.d.cts`, `.cjs`. Extensionless names
try exact spelling, those source/declaration extensions, then `index.ts`,
`index.tsx`, `index.d.ts`, `index.js`, `index.jsx`. Config inheritance follows
[TSConfig relative-path rules](https://www.typescriptlang.org/tsconfig/extends.html).
C/C++ also recognizes Objective-C extensions `.m` and `.mm`.

Test edges participate by default. Go `_test.go` files retain their declared
package, including external `package_test` names; an import expanded into a
test file also carries `test`. Rust `#[cfg(test)]` items, `#![cfg(test)]` files
and `mod tests` modules carry `test`, inherited by nested file modules and
inline bodies. Other cfg expressions are retained lexically without guessed
evaluation. Python recognizes `test_*.py` and `*_test.py`; JS/TS recognizes
`*.test.*`, `*.spec.*` and files below `__tests__`. Other test layouts need
caller classification through `Graph.fromEdges`. Ambiguous directory names
such as Python `tests` alone do not classify a helper file as test code.

`Options.python_initializers` selects the package-initializer policy:

| Policy | Edges |
|---|---|
| `.ancestors` (default) | Literal modules and selected initializer ancestors below the import search root. |
| `.explicit` | Direct modules only. A `from package import child` statement uses selected child modules; it retains the package when an imported name has no selected child module. |
| `.modulefinder` | Ancestors, plus the package ancestry that modulefinder visits for `from . import name`. |

`Options.python_star_reexports` defaults to true. For `from x import *`, gantry
always records `x`; it additionally follows named top-level imports exported
by a literal `__all__` list or tuple in the selected source of `x`. Aliases
are honored. Set the option to false for a graph of literal modules
only. Computed/augmented export lists, conditional exports, star chains,
runtime reassignment, `__getattr__` and exports without literal `__all__` are
not evaluated. There is no speculative enumeration of package submodules.

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
| `build.zig.zon` | Whole-document ZON validation and the root struct's `.dependencies`; quoted field names, URLs, paths, hashes and multiline strings. |
| `package.json` | Dependencies, dev, peer and optional dependencies, with their string requirements. Uses `std.json`. |
| `Cargo.toml` | Normal, dev, build, workspace and target dependency tables, inline dependency tables and separate per-dependency tables; versions, git, path and `workspace = true`. |
| `go.mod` | `require` lines and blocks; full module paths, versions and sources. |
| `pyproject.toml` | PEP 621 project and optional requirements, string dependency groups, and Poetry dependency groups; extras, markers and direct URLs remain in the requirement. |

The ZON reader uses Zig's standard parser to validate the whole document
before extracting the root struct's dependencies. Nested dependency blocks
are ignored. Invalid syntax, duplicate fields, a non-struct root or dependency
map, non-struct dependency entries, non-string URL/path/hash fields, conflicting
URL/path fields and non-boolean lazy fields return `InvalidManifest`. Unknown
fields still undergo ZON validation. This reads declarations; it does not
validate the compiler's package schema, fingerprints or hash contents.
The TOML and Go readers extract declarations; they are not full format
validators. JSON and malformed dependency shapes are errors. General TOML
multiline strings, dotted dependency keys, dependency-group inclusion,
workspace inheritance resolution and lockfiles are outside scope. Go
replacement/workspace routing is separate from dependency declarations. Partial declarations are not returned after an extraction error.

## Rules

`rules.Rules` is data. `ordered` contains named sets of layers, lowest first.
Each layer has path patterns; the first match wins, and an unspecified file
defaults to layer 0. An edge to a higher layer is a violation. Computed graph
depths and caller-declared rule layers are separate things.

`forbidden` matches source and target patterns, optionally an edge kind.
`nothing_imports` matches a target; it can keep entry files imported by nobody.
`allowed` names the restriction it exempts, plus source/target patterns and
an optional `kind`. For example, `.allowed = &.{.{ .rule = "layers", .kind =
.@"test" }}` lets tests import any layer while keeping the named layer rule
for production edges. Reference rules also accept a source `kind` filter.

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
ordering and ownership. Config inheritance, local Go routing, test kinds,
target selection and Python policies have regression fixtures. Generated graphs are checked against transitive
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
