"""Use the prepared virtualenv interpreter, independent of entry-point shebangs.
With BENCH_PHASES set, pydeps' import and its run go to stderr apart."""
import time
started = time.perf_counter()
import os
import runpy
import sys
import pydeps.pydeps
imported = time.perf_counter()
try:
    runpy.run_module('pydeps', run_name='__main__')
finally:
    if os.environ.get('BENCH_PHASES'):
        sys.stdout.flush()
        print(f"PHASE\timport\t{(imported - started) * 1000:.3f}", file=sys.stderr)
        print(f"PHASE\tanalysis\t{(time.perf_counter() - imported) * 1000:.3f}", file=sys.stderr)
