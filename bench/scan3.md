# Zig reference scan, 2026-10-08

The baseline is gantry `206e02596eef31dd4736334e3ffadf7af83d3bcc`.
The candidate is the commit containing this report. Apple M3 Max, aarch64
macOS 26.2, Zig 0.17.0; all modules use ReleaseFast. The machine is shared.
Raw samples, full evidence and the supplementary replay are in [scan3.json](scan3.json).

The input is the same [relic](https://github.com/pedronaugusto/relic) package
as [scan2](scan2.md):
`relic-0.3.0-n6Y3YJedSgDUfQ9Wk2p8hoZflLq4LroDBdl-iaenXGcV`,
archive SHA-256 `7274bc1198f86e158389499e196a50f3a621ff26b8a350281d630b521a29562c`.
Its **src** directory has 178 selected files, including 157 Zig files.
The archive checksum was verified before scanning.

## Cause and change

Sampling complete real scans for five seconds at 1 ms intervals identified
1,101 samples under `recoverShaped`, including 136 at the generic slice-equality
call for the alias-member dot check. Disassembly showed a call to `mem.eql` for
a single fixed punctuation byte in the reference loop. The two alias-dot checks
now test kind, length and byte directly. They preserve `Token.is(".")` semantics,
including supplied word tokens. The final profile has no generic equality call
at those checks. Other comparisons and all declaration-reference work remain.
A more selective declaration-name sketch and broader equality inlining did not
improve real scans and were discarded.

The napkin target was 0.365 ms, about 11% of the prior 3.409 ms isolated
reference pass. The final complete memory scan saves 0.652 ms against main.
The measured change is confined to Zig recovery; sweep is unchanged.

## Historical target and matched A/B

Use the identical [scan.zig](scan.zig) harness, flags and controls on every side:
`scan CORPUS/src 6`, five sequential blocks alternating before/historical/after
and after/historical/before, no compiler running. This yields 30 interleaved
memory and 30 directory samples per side. No samples were discarded.
Sweep stays at `394604ecf4e49e1ee18d58d4a9f49914258ebce5`; every side uses
shakedown `d5d19d39bc60cec59456aca947a3a7b484b87318`. The shakedown
update is applied equally to the controls and is outside the timed scan.

The historical control restores the lexer at scan2's recorded baseline
`be981ec6d707d4213428e76aa74466474edc0078`, and recovery from
`b350947b235d27c6d6236166c928174d3795309a:src/lang/zig.zig`, renaming
`indexOfAny` to `findAny` and retaining main's resolver. Its scan dispatch uses
`recoverTokens(…, lex(…))`, the historical entry path, rather than `recoverSeen`.
It is a timing target only: it omits required test/dead classification.

| Real scan, ms | Best | Median | Range | Spread |
| --- | ---: | ---: | --- | ---: |
| memory, before | 18.171 | 18.291 | 18.171–18.986 | 0.815 |
| memory, historical | 17.771 | 17.925 | 17.771–18.520 | 0.749 |
| memory, after | 17.519 | 17.739 | 17.519–17.975 | 0.456 |
| directory, before | 20.086 | 20.248 | 20.086–21.601 | 1.515 |
| directory, historical | 19.674 | 19.917 | 19.674–48.718 | 29.044 |
| directory, after | 19.380 | 19.620 | 19.380–20.860 | 1.480 |

Best memory improves **3.59%** against main and **1.42%** against the matched
historical replay. Relative to scan2's recorded **17.774 ms**, the final
**17.519 ms** is **−1.43% (−0.255 ms)**: the original +2.05% debt is closed.
Memory median is 1.04% below the recorded historical 17.926 ms median.
Directory best improves 3.51% against main and 1.49% against the matched
historical replay (1.71% against the recorded 19.718 ms).

A supplementary 30-sample comparison gives the old recovery the **new main
lexer** too. This is a different, faster timing target:

| Real scan, ms | Best | Median | Range | Spread |
| --- | ---: | ---: | --- | ---: |
| memory, before | 18.122 | 18.550 | 18.122–19.011 | 0.889 |
| memory, pre | 16.567 | 16.845 | 16.567–51.656 | 35.089 |
| memory, after | 17.537 | 17.868 | 17.537–19.038 | 1.501 |
| directory, before | 20.013 | 20.801 | 20.013–40.639 | 20.626 |
| directory, pre | 18.351 | 18.819 | 18.351–34.291 | 15.940 |
| directory, after | 19.306 | 19.883 | 19.306–36.156 | 16.850 |

That recovery-only replay is 16.567 ms best; the candidate in that block is
17.537 ms, a **+5.86% (+0.970 ms)** miss. It includes lexer gains made after
the recorded historical control. This narrower replay remains faster; the
requested historical debt is closed, not every possible classification overhead.

## Correctness and allocation

Main and candidate retain digest `f6ed8a0eaa2edb7d`: 1,089 edges,
14,695 references (8,271 import, 6,424 test), 46 dead flags, 142 SCCs and
six cycles. The digest covers paths, edges, references, unsupported and invalid
records, including offsets, kinds and dead flags. The historical replay's
digest is `fe744a29aef0577`; its different classifications are never an oracle.

Both main and candidate allocate 36,253,114 bytes in 35 allocator calls,
with 11,877,730 peak live bytes. Neither required classification nor collision
chains, bounded workspace, token observers or references were removed.

## Affected synthetic workloads

[ops.zig](ops.zig) samples each operation for 200 ms after warm-up. Nine
sequential A/B blocks alternate order. Scan medium is 5,000 files; the Zig
import row uses the unchanged medium fixture from [fixtures.zig](fixtures.zig).

| Synthetic, ms | Before best / median / range | After best / median / range | Best change |
| --- | --- | --- | ---: |
| imports/zig | 0.091560 / 0.093631 / 0.091560–0.095575 | 0.089198 / 0.091379 / 0.089198–0.240772 | -2.58% |
| scan/memory | 4.022045 / 4.094054 / 4.022045–4.220982 | 3.963337 / 4.038716 / 3.963337–4.139473 | -1.46% |
| scan/tokens | 4.355562 / 4.460378 / 4.355562–4.571758 | 4.311796 / 4.390897 / 4.311796–4.547441 | -1.00% |
| scan/sequences | 5.069003 / 5.168252 / 5.069003–5.307845 | 4.991099 / 5.116744 / 4.991099–5.311632 | -1.54% |
| scan/diagnostic | 3.999470 / 4.127387 / 3.999470–13.233005 | 3.938118 / 4.065389 / 3.938118–4.157302 | -1.53% |

Every scan row keeps its allocation bytes/calls and output counts. Synthetic
memory remains 3,753,484 bytes / 23 calls, 5,499 edges and references.
These rows supplement the real-source result.

## Validation and build controls

Thirty-four targeted Zig tests pass natively and on x86_64 macOS/Rosetta:
classification through transitive production/test roots, dead imports, methods,
Self/decl literals, collision chains through 3,000 names, the 8 KiB short-file
allocation bound, NoResize allocation failures, structural spills, truncated
input and immutable token recovery. Nineteen token/sequence checks also pass.
`zig build lint` and `zig build check` pass. No timing threshold gates correctness.

The final preflight pin remains its current main,
`9af905ed85cab6dbb19d9431c65ee3f41fbaa74d`; shakedown advances to current main
`d5d19d39bc60cec59456aca947a3a7b484b87318`, lazy and declared as a test dependency.
The build now exposes `zig build plan -- --tier fast|merge|release` through
preflight's planner. All three tiers, including portable compile/run matrices,
match the committed workflow. README still describes work in progress.
Hosted fast and merge gates apply to the exact commit containing this report.
