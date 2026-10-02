Use `../quiet.sh` for the complete pinned before/after pass. `run.sh` is the
lower-level current-checkout comparison helper. The quiet wrapper uses the
same adapters and pins, and records no elapsed values in smoke mode.

# Real repository comparison

```
bench/compare/run.sh
```

The default run installs pinned comparison tools, checks out pinned repositories, builds
gantry with Zig 0.16.0 in ReleaseFast, collects agreement, then measures five
warm runs. Use a quiet machine. Setup, compilation, normalization and reporting
are outside the measured commands. Each tool runs once before measurements;
subsequent runs rotate the tool order within each repository. No cold-cache
claim is made. Both wall time and peak RSS are saved for every run.

```
bench/compare/run.sh --scratch /path/to/scratch --runs 5
bench/compare/run.sh --agreement-only
bench/compare/run.sh --smoke
```

Scratch defaults to `tempfile.gettempdir()/gantry-compare`. Output defaults to
`<scratch>/results`, `agreement`, or `smoke`. Override with `--output`.
`--languages typescript python go rust zig` selects cases. `--skip-setup` reuses
an installation; corpus hashes and tracked content are still checked. Setup
never checks out a moving branch or runs a corpus's install scripts.

`--agreement-only` invokes each graph command once and records **no timings**.
`--smoke` selects small subsets in all five languages and runs each graph once, without timing.
Python and compiler-backed tools still discover their packages; normalization limits their
output to the selected universe. Smoke checks graph adapters and records no timing values.

Prerequisites: git, Zig 0.16.0, Python with venv, Node 22, Cargo/Rust >=1.91,
and Go compatible with Kubernetes' checked-in workspace. `PYTHON=/path/to/python`
selects the harness interpreter and the venv interpreter. The reference
environment's exact versions are in `pins.json:toolchains`; each report also
records the actual versions. On this host Python 3.13.2 was used because the
Homebrew Python 3.14.7 ensurepip fails while reading the host's macOS version.
On macOS, the existing Homebrew Node 22 bin directory is used if Node is not
already on PATH. No toolchain is installed globally by this harness.

## Pins and isolation

| Tool | Version | Pin |
|---|---|---|
| madge | 8.0.0 | `pins.json:npm`, complete `npm-lock.json` |
| dependency-cruiser | 16.10.4 | `pins.json:npm`, complete `npm-lock.json` |
| TypeScript parser/resolver | 5.7.3 | `pins.json:npm`, complete `npm-lock.json` |
| pydeps | 3.0.8 | `pins.json:python`, all dependencies in `requirements.txt` |
| import-linter / Grimp graph | 2.15 / 3.17 | `pins.json:python`, `requirements.txt` |
| go list | go1.27.1 reference toolchain | `pins.json:toolchains`, actual version in report |
| cargo-modules | 0.26.0 | `pins.json:cargo`, `cargo install --locked` uses that release's Cargo.lock |

`setup.py` installs npm with a local prefix at `<scratch>/npm`, Python into
`<scratch>/venv`, and cargo-modules with `cargo install --root <scratch>/cargo`.
`GOPATH`, Go module/build caches, Cargo home/target, npm/pip caches and Zig's
global cache point inside scratch. There is no Go comparison tool binary to install:
the selected Go comparison uses `go list -deps -json`, which also underlies
goda. npm user/global config and pip config are disabled; Go's personal env
file is disabled. Installed Rust toolchain binaries are used directly so
the corpus's rustup override cannot install another toolchain. The corpus's
checked-in Cargo configuration and Go workspace are inputs to those tools.

Repository URLs and **full commit hashes** are in `pins.json:repositories`.

| Language | Repository revision | Selected source |
|---|---|---|
| TypeScript / JavaScript | VS Code 1.96.4 | all supported JS/TS extensions in `src` |
| Python | Django 5.1.5 | `django`, including package initializers and migrations |
| Go | Kubernetes 1.32.1 | `pkg/...` sources and repository packages in their compiler dependency closure |
| Rust | rust-analyzer 2025-02-17 | the `ide` library, `crates/ide/src` |
| Zig | Zig 0.14.0 | `lib/std` |

The Rust case is a selected library in the real rust-analyzer workspace,
not a claim to cover every workspace crate. The Go command uses the pinned
`go.work` and vendor tree, excludes tests and selects the host platform.
Gantry sees all tracked Go files in those discovered package directories,
including tests and inactive variants, plus selected go.mod identities.
External/vendor edges are excluded from both normalized graphs. Kubernetes'
staging workspace packages remain repository-internal nodes, exposing the
documented absence of replacement/workspace resolution in gantry.

## Graph agreement

Direction is importer → dependency. Edges are sets, ignoring multiplicity.
TS/JS and Python normalize to repository-relative **file** pairs. Go collapses
gantry's file expansion to repository-relative **package directory** pairs;
compiler ImportPaths map through their `Dir`. Rust collapses cargo-modules'
item/type/inline-module nodes to their longest selected **file module** prefix,
such as `ide::hover`. File module declarations are retained as dependencies.
Module/package self edges are removed on both sides; file self edges remain.
No transitive closure is added. Normalization admits an edge only when both
endpoints are in the same selected repository universe.

VS Code comparison tools use a scratch-local tsconfig with `baseUrl=<repo>/src`, type
imports enabled, and no installed external dependencies. Madge's warnings
and dependency-cruiser's unresolved records remain in raw output. Grimp is
the actual graph engine used by import-linter; persistent graph caching is
disabled. pydeps uses bytecode/modulefinder, `--no-config`, and no diagram rendering.
cargo-modules uses default features, without `cfg(test)` or external/sysroot
nodes. Its resolved re-exports and type dependencies go beyond lexical imports.

`report.md` gives agreed, gantry-only and comparison tool-only counts, samples, and
counts by reason. `report.json` carries commands, pins, source revision/tree,
environment, every measurement and the same agreement summary. Each
`<language>/<tool>.raw` and `.stderr` preserves the original output. Sorted
`*.edges.json` lists every normalized pair. `*.differences.json` lists **every**
disagreement with its class, reason and witness. `review:` means an unexplained
difference requiring inspection, never an automatic scope exemption or bug
claim. Review raw output and the pinned source before changing gantry.

Known differences in the checked-in agreement report:

- TS aliases and declaration-file resolution; gantry's exact `.js` convention
  differs from madge's type declaration preference.
- Python package initializer bookkeeping; pydeps additionally skips migration
  discovery and follows star re-exported symbols.
- Go test files, inactive build variants, and workspace/replacement imports.
- Rust test modules versus `cfg`, and semantic definitions/re-exports/types
  versus gantry's documented lexical module resolution.

Agreed edges have identical normalized endpoints within these scopes. Zig
has no comparison tool: its graph and sample are reported, with no agreement score.
These comparisons do not validate manifests, layers or cycle algorithms.

## What the speed numbers mean

The measured child command includes startup, source discovery, file reads,
parsing/resolution and graph serialization to a file. Gantry reads its
prepared selection policy then walks the selected directories itself. Go
package-discovery metadata is prepared once, outside timing, to select the
same repository package universe for gantry. Compiler/cargo workspace work
performed by the comparison tool remains part of its graph command. Gantry has manifest
declarations disabled, although Go module identities are read for resolution.
Analysis, visualization, contracts and rule checking are excluded.

Wall time uses a monotonic clock. `wait4` reports peak RSS of the command
(bytes on Darwin, KiB converted to bytes on Linux), including the highest
descendant RSS reported by the OS. This is **not** the summed simultaneous
memory of a process tree. The script supports macOS and Linux, not Windows.
Each measured graph must match its warmup graph or the run fails. Medians
are convenient summaries; keep the individual samples and environment.

The initial full agreement pass and the smoke test are checked in under
`results/`. `edges.json.gz` contains all selected paths, complete normalized
graphs and every disagreement with its witness. It can be read with Python:

```
import gzip, json
with gzip.open("bench/compare/results/edges.json.gz", "rt") as stream:
    edges = json.load(stream)
```

`agreement.md` / `.json` and `smoke.md` / `.json` are the reports. The
agreement's source commit records the harness before these artifacts were
added; its `src` tree is also recorded. Raw tool output remains in the chosen
scratch directory. No real benchmark timings were collected on the busy host.
Those historical reports describe the earlier source revision; rerun agreement against the pinned current main before interpreting differences. Scope differences are not evidence that either graph is universally
correct; the full diff remains available for review.

Adapter checks: `python3 bench/compare/test_adapters.py`. These cover edge
direction, external filtering, Python initializer mapping, Go's streamed JSON
and Rust item collapse. `zig build test -Doptimize=ReleaseFast` checks gantry.
