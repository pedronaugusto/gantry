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
required-path strings; keep those alive and free only the returned findings slice.

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

Import recovery uses byte lexers for Zig, C/C++, JavaScript/TypeScript, Python, Go and
Rust. Resolution stays within selected files. Zig named modules and C include roots are
caller inputs; JS/TS aliases come from selected local configs; Python initializer and
literal star-reexport handling are selectable; Go uses selected module/workspace routing
and optional target constraints. Rust resolves file modules and crate-relative use paths
without macro expansion.

Rust test classification propagates through file modules; owned recovered operands let it share each available source read with import resolution.

`graph.references()` keeps import spellings, offsets, kinds and resolution status.
Detectable unsupported constructs appear in `graph.unsupported()` without guessed edges.
`strict_imports` refuses the first such construct with `UnsupportedImport`, even when
import edges are disabled. An unresolved supported literal is a reference, not an
unsupported construct. Loader aliases, generated imports and other runtime semantics can
remain undetected.

Import and test edges are enabled by default; links and assets require explicit kind
selection. Markdown recovery handles inline relative links and wiki links while
excluding fenced code and comments. Asset recovery matches path tokens in supported text
files. Manifest declarations from `build.zig.zon`, `package.json`, `Cargo.toml`,
`go.mod` and `pyproject.toml` remain separate from file edges. The TOML and Go
declaration readers do not validate their entire formats.

## Graphs and rules

Edges point from an importer to its dependency and count reference occurrences.
Construction sorts and coalesces them; caller edges go through `Graph.fromEdges`.
Aggregation keeps self edges within directories. Analysis collapses strongly connected
components for layer calculation; depth is the longest path from a root, and each cycle
has one closed witness path. An isolated file has depth zero.

Rules restrict ordered layers, source/target patterns, raw references, required paths
and cycles. Exceptions apply to a named restriction. Path patterns use `*` and `?`
within a component and `**` across components. Every matching restriction reports in
rule order. These rules operate on the recovered graph.

## Scope

- It does not discover a repository, apply gitignore rules or select files for the caller.
- It does not invoke a compiler, preprocess source or evaluate build scripts and macros.
- It does not construct symbol, call or runtime dependency graphs.
- It does not install packages or solve transitive external versions.
- It does not implement complete language, CommonMark, TOML or asset-format grammars.
- It does not render a graph or provide a command-line linter.

<!-- performance: quiet pass -->

## Testing

Local build scripts clear `.zig-cache/{o,h,z,tmp}` above the measured cap in `ci/cache.sh`; run `sh ci/cache.sh` before direct Zig builds (only a rebuild is lost).

`zig build test` runs the suite and usage example in Debug by default. Fixtures cover
lexical exclusions, resolvers, manifests, diagnostics, strict imports and rules.
Generated graphs are checked against independent reachability and depth calculations;
allocation-failure tests check cleanup. `zig build examples` runs the example
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
