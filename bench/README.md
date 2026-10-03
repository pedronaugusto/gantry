# gantry benchmark preparation

Keep the `bench` worktree in the workspace’s `.bench/gantry`, outside `.zig-cache`; `bench/quiet.sh` resolves its files from its own directory.

Pinned after: `2a0464cd218f4752fb75aa45d3670600e582947b`, the `mem` branch head (final main
`277ee0c` with the scan memory fixes).
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
`--check-prepared` write `prepared.md` / `prepared.json`. None of them can
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
The timing pass adds no tool. Agreement-only cases outside it: `nim genDepend`
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

Quiet-only planning estimate: **4–15 minutes**. See [QUIET-PREP.md](QUIET-PREP.md) for preparation, counts, sizes and assumptions.

Standalone `zig build -Doptimize=Debug` compiles the pinned after harness
without running it. Snapshot builds pass `-Dsnapshot=true` to compile the
archived local revision instead; quiet runs retain ReleaseFast.
