# Agreement after resolution changes

`agreement.md` and `agreement.json` record an agreement-only run of the
`origin/bench` harness at `b2ba26c9da2a39dee65f2bff2f28c87e70ab0c62`, against
the clean `design` source revision and tree recorded in the report. Repository
and rival pins, actual tool versions and commands are in the JSON report.
`edges.json.gz` contains the selected scan paths, all normalized graphs and
**every** disagreement with its reason and witness. Counts were checked
independently against the complete edge sets. No timing samples were taken.

The harness ran in a separate worktree. Its build module was pointed locally
at `design/src/gantry.zig`; `--gantry-source` recorded the design revision.
Those pointer changes were not committed. The existing scratch installations
and pinned checkouts were reused with `--skip-setup --agreement-only`.
Raw outputs remain at `/private/tmp/gantry-compare/design-final` on the run
machine. Corpus content checks and all four adapter tests passed.

Caller policies used for this comparison:

- VS Code: the same supported source files in `src`; selected repository
  JSON configs supply `tsconfig`/`jsconfig` and local `extends` inputs.
  Config nodes and other JSON files are excluded from the normalized source
  universe. Import and test edges both participate, as in the rivals.
- Kubernetes: the existing `pkg` package closure; selected `go.work` and
  `go.mod` files. Only `import` edges participate. The caller supplies
  `darwin/arm64`, matching `go env GOOS GOARCH`, with explicit `gc`, `cgo`
  and release tags. Tests and inactive sources remain graph metadata.
- rust-analyzer ide: only `import` edges participate. No semantic resolution,
  macro expansion or general Rust cfg evaluation was added.
- Django / pydeps: `python_initializers = .modulefinder` and literal star
  reexports enabled, with pydeps' original command and default noise limit.
- Django / Grimp: `python_initializers = .explicit` and star reexports
  disabled. This produces the same direct-import graph as Grimp.

Every remaining difference has a witness:

- Dependency-cruiser selects runtime `.js` files on 29 imports for which
  TypeScript extension substitution selects `.d.ts`. These are 29 edges
  on each side, with the same importers. Madge matches TypeScript here.
- Pydeps' default noise threshold (200) removes `django.utils` and
  `django.core`, which have degrees 314 and 271. Raising the threshold to
  1,000,000 recovers exactly 577 of the gantry-only pairs; that supplemental
  graph is included in the archive. The other 128 gantry-only pairs come
  from migration sources omitted by pydeps' dummy entry discovery.
- Pydeps also discovers `operations/base.py` through its star-submodule
  enumeration. The literal `operations.__all__` does not export it, so
  gantry retains the named module and known reexports without inventing it.
- Cargo-modules supplies 42 semantic definition, reexport and type edges.
  Their exact DOT witnesses are in the archive. Eleven had coincided with
  gantry's test imports in the old all-source graph; filtering tests removes
  that coincidence. The new production comparison has 115 agreed pairs.

Go, Grimp and madge have no disagreements in these scopes. Zig's 996 edges
have no rival score. Exact agreement in one selected repository is not a
claim that the library reproduces every compiler or runtime environment.
