# gantry measurements

```
zig build bench -Doptimize=ReleaseFast
python3 bench/run.py
```

The script creates and removes a temporary corpus: 30,002 files, six code
languages, 30,711,680 source bytes. The scan produces 75,000 edges, 35,000
references and two manifest declarations. Comment and string decoys are
included. Go package imports expand to ten selected files each.

Apple M3 Max, Zig 0.16.0, ReleaseFast, one calling thread, 2026-09-30:

| Operation | Measured |
|---|---|
| Path listing | 82.657 ms |
| First scan, files just written | 690.937 ms |
| Subsequent filesystem scans | 573.082–673.962 ms |
| Scan with caller-held bytes | 32.260–33.533 ms |
| SCCs, cycle witnesses and longest depths | 5.614–6.055 ms |
| Directory aggregation, depth 2 | 5.011–5.180 ms |

Generation and listing are outside scan timing; file opens, reads, path
indexing, lexing, resolution, declarations and output ordering are inside.
Memory loading is outside the memory scan timing. These are synthetic files
about 1 kB each, mostly comments. Files just written are not a cold disk.
The measurements are not a throughput promise for arbitrary source shapes
or storage. There is no absolute-time test or CI performance gate.

The harness stays on `bench`, outside the package paths. Rebase this branch
on `main` to measure a later version; do not merge the harness into `main`.

Library revision measured: `f31c921`.
