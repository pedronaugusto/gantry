#!/usr/bin/env python3
"""Generate 30,002 files in a temporary directory, then time actual reads.

Usage: zig build bench -Doptimize=ReleaseFast
       python3 bench/run.py

No threads, subprocesses, or file selection are used inside the timed scan.
The corpus is generated before running the executable. Five rounds expose
warm-cache variation. All temporary files are removed on exit.
"""
import pathlib
import subprocess
import tempfile

with tempfile.TemporaryDirectory(prefix="gantry-bench-") as scratch:
    root = pathlib.Path(scratch)
    total = 0
    for lang in ("zig", "c", "js", "py", "go", "rust"):
        for i in range(5000):
            group, member = divmod(i, 10)
            prev = max(0, member - 1)
            if lang == "zig":
                path = f"zig/g{group}/f{member}.zig"
                text = f'const dep = @import("f{prev}.zig");\n'
                filler = "// " + "comment " * 120 + '\nconst text = "@import(\\"fake.zig\\")";\n'
            elif lang == "c":
                path = f"c/g{group}/f{member}.h"
                text = f'#include "f{prev}.h"\n'
                filler = "/* " + "comment " * 120 + ' */\nconst char *s = "#include fake";\n'
            elif lang == "js":
                path = f"js/g{group}/f{member}.ts"
                text = f"import './f{prev}';\nconst dep = import('./f{prev}');\n"
                filler = "// " + "comment " * 120 + "\nconst text = `import './fake'`;\n"
            elif lang == "py":
                path = f"py/g{group}/f{member}.py"
                text = f"import g{group}.f{prev}\n"
                filler = "# " + "comment " * 120 + '\ntext = "import fake"\n'
            elif lang == "go":
                path = f"go/g{group}/f{member}.go"
                text = f'package g{group}\nimport "example.com/bench/g{max(0, group - 1)}"\n'
                filler = "// " + "comment " * 120 + '\nvar text = `import "fake"`\n'
            else:
                path = f"rust/src/g{group}/f{member}.rs"
                text = f"use super::f{prev}::Thing;\n"
                filler = "// " + "comment " * 120 + '\nlet text = r#"use crate::fake;"#;\n'
            dest = root / path
            dest.parent.mkdir(parents=True, exist_ok=True)
            data = (text + filler).encode()
            dest.write_bytes(data)
            total += len(data)
    (root / "go/go.mod").write_text("module example.com/bench\nrequire example.com/external v1.0.0\n")
    (root / "package.json").write_text('{"dependencies":{"external":"1"}}\n')
    print(f"source bytes {total:,}; six languages, 5,000 files each", flush=True)
    subprocess.run(["zig-out/bin/scan", str(root)], check=True)
