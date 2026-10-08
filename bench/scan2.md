# Zig scan structure, 2026-10-08

The baseline is gantry `be981ec6d707d4213428e76aa74466474edc0078`.
The final source is the commit containing this report. On an Apple M3 Max,
aarch64 macOS 26.2, Zig 0.17.0, all modules use ReleaseFast.
Raw samples and classification/allocation evidence are in [scan2.json](scan2.json).

The real-source input is [relic](https://github.com/pedronaugusto/relic)'s package
`relic-0.3.0-n6Y3YJedSgDUfQ9Wk2p8hoZflLq4LroDBdl-iaenXGcV`, archive SHA-256
`7274bc1198f86e158389499e196a50f3a621ff26b8a350281d630b521a29562c`.
Use its **src** directory: 178 selected files, including 157 Zig files. Scanning
the whole package includes extra sources and is a different workload.

Build the same [scan.zig](scan.zig) harness for both versions, including its new
untimed evidence output, and run `scan CORPUS/src 6`. Run five blocks, alternating
before/pre/after and after/pre/before, sequentially, with no compiler running:
30 memory and 30 directory samples per version. Sweep remains at
`394604ecf4e49e1ee18d58d4a9f49914258ebce5`; the timing harness uses the same prior
shakedown dependency on every side. Dependency updates are outside this A/B.
The pre-context replay replaces only Zig recovery with
`b350947b235d27c6d6236166c928174d3795309a:src/lang/zig.zig` (the parent of
`441acce`), renames the old std.mem.indexOfAny to findAny, and retains the current
resolver so named-module resolution is comparable. It lacks required test/dead
classification, and serves only as the historical timing target.

| Real scan, ms | Best | Median | Range | Spread |
| --- | ---: | ---: | --- | ---: |
| memory, before | 20.429 | 20.544 | 20.429–21.315 | 0.886 |
| memory, pre | 17.774 | 17.926 | 17.774–18.655 | 0.881 |
| memory, after | 18.139 | 18.252 | 18.139–18.799 | 0.660 |
| disk, before | 22.443 | 22.590 | 22.443–24.808 | 2.365 |
| disk, pre | 19.718 | 19.878 | 19.718–21.138 | 1.420 |
| disk, after | 20.121 | 20.386 | 20.121–37.043 | 16.922 |

Best memory scan improves 11.21%; directory scan improves 10.35%.
The remaining pre-context memory miss is **+2.05% (+0.365 ms)**.
The directory samples include first-pass outliers; no sample was discarded.

Before and after have the same graph/reference digest `f6ed8a0eaa2edb7d`:
1,089 edges, 14,695 references (8,271 import, 6,424 test), 46 dead flags,
142 SCCs and six cycles. The digest includes paths, edges, references, unsupported
and invalid records, including offsets, kinds and dead flags. The historical replay
has different classifications and one fewer coalesced edge; it is not a correctness
reference. Counting one complete memory scan outside timing gives:

| Allocation | Before | After |
| --- | ---: | ---: |
| Total bytes | 37,873,886 | 36,253,114 |
| Peak live bytes | 11,877,730 | 11,877,730 |
| Allocator calls | 36 | 35 |

The cause was structural work walking full token records after lexing and
out-of-line token emission. Declaration-reference lookup remains substantial. Structure now follows
emission directly. Bracket partners occupy existing 64-bit token padding:
40 bytes before and after. Open brackets, import prefixes, test marks and builtin
aliases use bounded inline lists which spill once and continue growing; they never
truncate. Their allocation no longer blocks normal arena token-buffer resizing.
Short files use smaller lists. Caller-supplied const tokens use an owned partner
table and are never mutated. Required declaration-reference work, test ranges,
roots, Self/decl literals and collision chains are retained; lookup state is passed
by pointer and the word lookup is specialized inline.

A diagnostic phase replay loads all 157 Zig sources, retains at most 1 MiB of
arena scratch per file, and times 30 corpus repetitions. It uses a uniform 4,096
slot declaration table and placeholder specs to isolate work, so it is not the
public scan timing. Best baseline lex + structural phase is 8.879 + 2.792 =
11.671 ms; the final fused phase is 9.996 ms. Declaration initialization is
0.207 → 0.213 ms, required word/reference work 3.265 → 3.409 ms, and reachability
0.122 → 0.123 ms. The required word pass remains a substantial cost and its
isolated row is 4.41% slower; full scanning uses the existing short/long table
specializations. Neither that miss nor the remaining real-corpus delta is hidden.

Run `ops scan/memory medium`, `ops scan/tokens medium` and
`ops scan/sequences medium` with [ops.zig](ops.zig): each samples for 200 ms
after warm-up. Nine sequential A/B blocks alternate order; medium is 5,000 files.

| Synthetic scan, ms | Before best / median / range | After best / median / range | Best change |
| --- | --- | --- | ---: |
| scan/memory | 4.078 / 4.138 / 4.078–9.694 | 4.039 / 4.099 / 4.039–14.135 | -0.95% |
| scan/tokens | 4.413 / 4.566 / 4.413–5.112 | 4.368 / 4.467 / 4.368–14.851 | -1.03% |
| scan/sequences | 5.228 / 5.258 / 5.228–5.313 | 5.031 / 5.073 / 5.031–5.245 | -3.77% |

An initial large builder regressed the short-file synthetic row about 4%; smaller
short-file scratch removed it. Synthetic memory allocation stays at 3,753,484
bytes / 23 calls with 5,499 edges and references. No sweep change or synthetic
result substitutes for the real-source A/B.

Validation: 34 targeted Zig tests pass natively and under x86_64 macOS/Rosetta,
including the prior 8 KiB short-file allocation bound, transitive test/dead roots,
method/decl literals and collision cases through 3,000 names. New checks cover
768 nesting levels, malformed/truncated sources, immutable replay tokens,
NoResize allocation failures, and overflowing short/long structural lists.
Nineteen token/sequence tests, two unsupported-recovery allocation checks, lint
and compile checks pass locally. Hosted fast and merge CI gate landing.
