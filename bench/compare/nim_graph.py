"""`nim genDepend` on one project file, its DOT graph printed unchanged.

genDepend writes `<project>.dot` beside the project file, then renders it
with Graphviz. A no-op `dot` on PATH stands in for Graphviz, so nothing is
installed; the DOT file is read and removed, leaving the corpus untouched.
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

repo, project, nimcache = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3])
nimcache.mkdir(parents=True, exist_ok=True)
dot = (repo / project).with_suffix(".dot")
with tempfile.TemporaryDirectory() as stub:
    (Path(stub) / "dot").write_text("#!/bin/sh\nexit 0\n")
    (Path(stub) / "dot").chmod(0o755)
    env = dict(os.environ, PATH=stub + os.pathsep + os.environ["PATH"])
    try:
        subprocess.run(["nim", "genDepend", "--hints:off", f"--nimcache:{nimcache}", project], cwd=repo, env=env, check=True, stdout=sys.stderr)
        sys.stdout.write(dot.read_text())
    finally:
        dot.unlink(missing_ok=True)
