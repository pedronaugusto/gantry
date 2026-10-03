import time
started = time.perf_counter()
import json
import os
import sys

import grimp

imported = time.perf_counter()

sys.path.insert(0, sys.argv[1])
# import-linter uses this graph engine. Disable its persistent graph cache.
graph = grimp.build_graph("django", include_external_packages=False, cache_dir=None)
edges = sorted((module, target) for module in graph.modules for target in graph.find_modules_directly_imported_by(module))
analysed = time.perf_counter()
json.dump({"modules": sorted(graph.modules), "edges": edges}, sys.stdout)
sys.stdout.flush()
if os.environ.get("BENCH_PHASES"):
    # Interpreter start before this script is the remainder of the wall time.
    for name, ms in (("import", imported - started), ("analysis", analysed - imported), ("output", time.perf_counter() - analysed)):
        print(f"PHASE\t{name}\t{ms * 1000:.3f}", file=sys.stderr)
