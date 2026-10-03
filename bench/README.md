# gantry benchmark preparation

Keep the `bench` worktree in the workspace’s `.bench/gantry`, outside `.zig-cache`; `bench/quiet.sh` resolves its files from its own directory.

Pinned after: `546bc06ca92caf8df21a63d9a1d95b162b1796da`, main's head (`revisions.json`).
**No main commit exists before the requested cutoff.** The initial main commit,
`24cc1cec108edf15a60a932ce79a864e811fec35`, is a clearly labelled substitute
baseline. This pass cannot establish a before/after result for a pre-cutoff
revision that does not exist.

`bench/quiet.sh` is the complete pass. `bench/quiet.sh --smoke` exercises
all available workloads once on tiny fixtures, without warmups or saved timing
values. Smoke is a correctness check, and never evidence for speed. Both
modes write plain Markdown and JSON to `bench/results/<local-date>/`; generated
results and build products are ignored. Smoke writes `smoke.md` / `smoke.json`;
the quiet pass writes `report.md` / `report.json`; preparation and
`--check-prepared` measure nothing and write nothing to results, so neither can
overwrite a real pass. Use `--output <directory>` for a separate run on the same day.

The full pass warms each workload, then repeats A (before), B (after), and the
comparison tools five times. `--runs N` changes the repetition count. Setup,
fixture generation and compilation happen before the measured work. Both
package builds use the same harness, toolchain and workloads. Compilation uses
ReleaseFast. Sources come from `git archive` of the pinned revisions, independent
of the working checkout or later main changes. `--before <revision>` and
`--after <revision>` explicitly override the pins in `revisions.json`.

The cutoff is `2026-09-30T00:00:00+01:00` (Lisbon). Use an explicit midnight:
Git's date-only `--before=2026-09-30` retains a time of day. Reports record the
full package revisions, harness revision, machine model, OS, CPU, memory and
tool versions, without a hostname or personal paths. Keep the raw samples;
these are warm-cache measurements, with no cold-disk or universal speed claim.

`PYTHON` overrides the interpreter. With it unset, the wrapper prefers an
already installed Python 3.13 found by `uv`, then falls back to `python3`; it
installs no interpreter. This avoids the host's Python 3.14 ensurepip failure.
Requires installed Zig 0.16.0, Git, Rust/Cargo, Go and Python. Build dependencies
are pinned in the existing lockfiles. `--build-dir <directory>` changes the
scratch/build location. Run the full pass only in the owner's quiet window.

Harness history stays on `bench`; never merge this branch into main.

The complete pass includes the deterministic six-language synthetic corpus:
30,002 files, filesystem scan, caller-held memory scan, path listing, SCC and
cycle/depth analysis, and directory aggregation. Smoke uses 62 files (ten
source files per language plus the two manifests). Both revisions must produce
the known synthetic edge, reference and declaration counts.

Same-job tools retained on pinned repositories: madge 8.0.0 and
dependency-cruiser 16.10.4 on VS Code; pydeps 3.0.8 and Grimp 3.17 on Django;
Go `go list` on Kubernetes; cargo-modules 0.26.0 on rust-analyzer. Zig's standard
library has no same-job tool, and is scanned without an agreement score.
Go `go list` asks only for the fields the graph reads (see the equivalence audit below). Agreement-only cases outside it: `nim genDepend`
on the Nim 2.2.10 compiler and `jdeps` on Apache Commons Lang 3.17.0. See
[comparison methodology](compare/README.md) and
`compare/pins.json` for full repository and dependency pins.

Both package revisions participate in each real-repository graph round.
Within a revision each normalized graph must remain stable; before and after
may differ as resolution changes. The report compares pinned-after edges to
the other tools and retains every difference with its reason and witness.
Differences requiring review are kept visible rather than treated as success
or failure of a universal correctness claim. Wall time and per-child peak RSS
are recorded only in the full pass. Normalization is outside timing.

Smoke covers every language/tool: VS Code base/common, Django utils,
Kubernetes util/slice and its repository dependency closure, four selected
rust-analyzer ide source files, and Zig Random. Compiler-backed tools can
still process their package/workspace outside that selected output universe.
For the Go smoke case, empty internal-edge sets are legitimate; adapter
checks cover non-empty streamed package dependencies.

`--comparison-scratch <directory>` reuses the pinned comparison installation;
`--skip-setup` skips installation but still verifies pins, tool versions and
tracked corpus content. Defaults use `bench/build/comparison`. Requires Node
22 and Rust compatible with cargo-modules, in addition to the common tools.
No toolchain is installed globally. Keep the prepared scratch directory for
the quiet window to avoid repeating dependency installation.

Compatibility adapters borrow opaque paths, graphs and analysis observations
through methods when available. Generation and selected paths are identical.
The standalone bench build consumes each package revision directly. Existing
published agreement artifacts have personal/scratch paths redacted, and their
old smoke instrumentation values are removed.

Quiet-only planning estimate: **12–30 minutes**. See [QUIET-PREP.md](QUIET-PREP.md) for preparation, counts, sizes and assumptions.

## Every public operation

`ops.zig` runs each public operation in process on one revision; `ops --list`
names the ones that revision has, and an operation the before pin lacks gets one
`unavailable` row for `before`. Fixtures (`fixtures.py`, and an in-memory tree
inside `ops.zig`) are built during preparation. Per-file and in-memory workloads
repeat the operation for 200 ms after one untimed warm-up and report the mean
(`ns_per_op`); every side of a workload, the comparison tools included, must
report the same counts and the same source bytes, or the pass fails. Whole-tree
workloads (`process/*`) are timed from outside as processes, with wall time and
peak RSS, and each side reports its phases (start, imports, analysis) so tool
start-up stays apart from the work.

Sizes: imports per file 20 / 200 / 5,000; manifest declarations 10 / 100 / 1,000;
in-memory trees 100 / 5,000 / 50,000 files (groups of ten, each a ten-file cycle,
with cross-group edges); whole-tree workloads use the 30,002-file synthetic
corpus, 5,000 Markdown pages, or a 5,501-file Python package.

| Operation | Workload | Comparison (pin) |
|---|---|---|
| `imports` (Zig) | `imports/zig/<size>` | `std.zig.Ast` (Zig 0.16.0) |
| `imports` (C/C++) | `imports/c/<size>` | unavailable: no include lister short of a preprocessor; `cc -M` and libclang evaluate conditionals and need every header |
| `imports` (JS/TS) | `imports/javascript/<size>` | TypeScript `preProcessFile` (5.7.3) |
| `imports` (Python) | `imports/python/<size>` | CPython `ast` (3.13) |
| `imports` (Go) | `imports/go/<size>` | `go/parser` ImportsOnly (go1.27.1) |
| `imports` (Rust) | `imports/rust/<size>` | syn 3.0.6 |
| `imports` (Nim) | `imports/nim/<size>`, after only | unavailable: Nim's parser ships only inside the compiler |
| `imports` (Java) | `imports/java/<size>`, after only | javac parse via `JavacTask` (Temurin 21.0.12.1+1) |
| `manifests.parse` | `manifests/<file>/<size>` for `package.json`, `Cargo.toml`, `pyproject.toml`, `go.mod`, `build.zig.zon`; `pom.xml`, `build.gradle`, `.nimble` after only | Python `json`, `tomllib`, `tomllib`, `golang.org/x/mod/modfile` v0.41.0, `std.zig.Ast` ZON, Python `ElementTree`; Gradle and nimble unavailable (both only evaluate their scripts) |
| `scan` (caller-held bytes) | `scan/memory/<size>` | unavailable in process; whole-tree scans are the `<language>/graph` comparisons |
| `scanWithDiagnostic` | `scan/diagnostic/<size>`, after only | as `scan` |
| `scan` with `Options.tokens` | `scan/tokens/<size>`, after only | end to end in `process/tokens` |
| `scan`, Markdown links | `scan/links/<size>`; `process/links` | markdown-it-py 4.2.0 (CommonMark) |
| `scan`, asset paths | `scan/assets/<size>` | unavailable: no pinned tool recovers asset paths from text |
| `walk` | `process/walk`, and the synthetic listing | BSD `find -type f`, ripgrep 15.2.0 `--files` |
| `Graph.check`, each rule family | `rules/{ordered,forbidden,allowed,nothing-imports,references,required,cycles}/<size>`; `rules/tokens/<size>` after only | in process unavailable (the rule tools check only graphs they build); end to end: dependency-cruiser 16.10.4 in `process/check-js`, import-linter 2.15 in `process/check-python`, ripgrep `-w --count-matches` in `process/tokens` |
| `Graph.fromEdges`, `Analysis.init`, `Graph.analyze`, `Graph.aggregate` | `graph/{from-edges,analysis-init,analyze,aggregate}/<size>` | unavailable: no pinned tool takes a caller edge list |
| `path.normalize` | `path/normalize/<size>` | unavailable: `posixpath.normpath` and `std.fs.path.resolve` keep `..` above the root and accept absolute paths |
| `rules.matches`, `rules.matchesToken` | `match/path/<size>`; `match/token/<size>` after only | unavailable: the pinned tools match globs only inside interpreters |
| whole-tree `scan` + graph | `<language>/graph` (existing) | madge, dependency-cruiser, pydeps, Grimp, `go list`, cargo-modules |

Skipped as value helpers with no measurable cost: `languageOf`, `kindsOf`,
`manifests.supported`, `manifests.modulePath`, `path.dir/base/within/directory`,
`Dependency.scope/revision/shortName`, and the slice accessors of `Graph`,
`Analysis`, `Imports` and `Paths` (`Graph.contains` included).

## Equivalence audit

A comparison counts only when both sides do the same work on the same input.
Verdicts: (a) the harness was changed so they do; (b) the lead is a named
design difference in gantry; (c) the tool inherently does more, kept and labelled.
Ratios are from the 2026-10-03 quiet pass (real repositories) or diagnostic
single runs on the shared machine (per-operation rows); the next quiet pass
publishes.

| Comparison | Ratio | Verdict | What each side does |
|---|---:|---|---|
| go/graph vs `go list` | 4.3x | (a), then (c) | A bare `-json` computed `Stale` for every package, hashing all sources against the build cache; now `-json=ImportPath,Dir,Imports,GoFiles,CgoFiles,Error,DepsErrors` (same 2,665 packages and imports; diagnostic 2.0–2.3 s to 1.1–1.3 s). The rest is go list's build context: per-file GOOS/GOARCH and build-tag selection, cgo, vendor and module tables. |
| rust/graph vs cargo-modules | 240x | (c) | cargo-modules loads rust-analyzer's whole workspace and dependency sources, expands macros and resolves names before walking item edges; gantry lexes the selected crate's files and resolves file modules. Workspace discovery (`cargo metadata`, about 0.1 s) is timed alone in `rust/workspace-discovery`. |
| typescript/graph vs madge | 45x | (c) | madge parses every file to a full AST and resolves each specifier through filing-cabinet with filesystem probes; gantry lexes specifiers and resolves against the in-memory selection. Same 50,508 edges. Phases: node start about 30 ms, module load about 0.3 s, the rest analysis. |
| typescript/graph vs dependency-cruiser | 40x | (c) | TypeScript AST per file, enhanced-resolve with filesystem probes, module metadata and JSON inside `cruise()`; same start-up split as madge. |
| python/graph vs Grimp | 2.0x | (c), and start-up | Grimp's Rust parser builds a full syntax tree per module, multi-threaded; of its process time about 45 ms is interpreter start and import, leaving analysis near gantry's scan (within 1.5x). gantry adds package-initializer edges Grimp does not record. |
| python/graph vs pydeps | 52x | (c), not native | pydeps compiles each module to bytecode and follows `IMPORT_NAME` opcodes. |
| imports/rust vs syn | 8–9x | (c) | syn builds a typed tree of every item, expression and literal; gantry lexes and records `use`/`mod` paths. |
| imports/java vs javac | 9–49x | (c) | Each parse needs a fresh `JavacTask` (compiler context) and builds a full tree; the JVM is not fully compiled within 200 ms. |
| manifests/go.mod vs x/mod modfile | 10–12x | (b) | modfile keeps a full syntax tree with comments and checks every module path and version; gantry's go.mod reader does not validate the format (documented in its README). |

Rows where gantry is not faster (diagnostic): `imports/go` (go/parser
ImportsOnly stops after the import block, about 2.5x faster), `imports/zig`
(`std.zig.Ast` about 1.5x faster), `manifests/build.zig.zon` (`std.zig.Ast`
ZON about 3.5x faster), `process/walk` (ripgrep), `process/tokens` (ripgrep
matches words in bytes and needs no import scan).

Standalone `zig build -Doptimize=Debug` compiles the pinned after harness
without running it. Snapshot builds pass `-Dsnapshot=true` to compile the
archived local revision instead; quiet runs retain ReleaseFast.
