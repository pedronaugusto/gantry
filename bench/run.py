#!/usr/bin/env python3
"""Deterministic six-language corpus; generation happens outside measurements."""
from pathlib import Path
import subprocess
import tempfile
import sys

def generate(root, count=5000):
    root = Path(root)
    total = 0
    for lang in ("zig", "c", "js", "py", "go", "rust"):
        for i in range(count):
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
    return total

if __name__ == '__main__':
    with tempfile.TemporaryDirectory(prefix='gantry-bench-') as scratch:
        smoke = '--smoke' in sys.argv
        generate(scratch, 10 if smoke else 5000)
        subprocess.run(['zig-out/bin/scan',scratch,'1' if smoke else '5'],check=True,
                       stdout=subprocess.DEVNULL if smoke else None,stderr=subprocess.DEVNULL if smoke else None)
        if smoke: print('Smoke passed; no timings recorded.')
