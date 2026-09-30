import json
import sys

import grimp

sys.path.insert(0, sys.argv[1])
# import-linter uses this graph engine. Disable its persistent graph cache.
graph = grimp.build_graph("django", include_external_packages=False, cache_dir=None)
edges = sorted((module, target) for module in graph.modules for target in graph.find_modules_directly_imported_by(module))
json.dump({"modules": sorted(graph.modules), "edges": edges}, sys.stdout)
