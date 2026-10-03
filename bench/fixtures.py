"""Deterministic fixtures for the per-operation workloads; built outside measurements.

Every source fixture is valid for the language's own parser, and every
comment or string spells an import that must not count."""
from pathlib import Path

# Imports per file: a small module, a large module, a generated file.
IMPORT_SIZES = {'small': 20, 'medium': 200, 'large': 5000}
# Declared dependencies per manifest.
MANIFEST_SIZES = {'small': 10, 'medium': 100, 'large': 1000}
EXTENSIONS = {'zig': '.zig', 'c': '.h', 'javascript': '.ts', 'python': '.py', 'go': '.go',
              'rust': '.rs', 'nim': '.nim', 'java': '.java'}
MANIFESTS = ('package.json', 'Cargo.toml', 'pyproject.toml', 'go.mod', 'build.zig.zon',
             'pom.xml', 'build.gradle', 'bench.nimble')


def source(language, n):
    out = []
    if language == 'go':
        out.append('package bench\n\nimport (\n')
        out += [f'\t"example.com/m{i}"\n' for i in range(n)]
        out.append(')\n\n')
    if language == 'java':
        out.append('package bench;\n\n')
        out += [f'import org.bench.m{i}.C{i};\n' for i in range(n)]
        out.append('\npublic class Big {\n')
    for i in range(n):
        if language == 'zig':
            out.append(f'const m{i} = @import("m{i}.zig");\n// @import("fake.zig")\nconst s{i} = "@import(\\"x.zig\\")";\nfn f{i}() u32 {{\n    return {i};\n}}\n')
        elif language == 'c':
            out.append(f'#include "m{i}.h"\n/* #include "fake.h" */\nstatic const char *s{i} = "#include \\"x.h\\"";\nstatic int f{i}(void) {{ return {i}; }}\n')
        elif language == 'javascript':
            out.append(f"import {{ a{i} }} from './m{i}';\n// import x from './fake'\nconst s{i} = \"import y from './z'\";\nexport function f{i}(): number {{ return {i}; }}\n")
        elif language == 'python':
            out.append(f'import pkg.m{i}\n# import fake\ns{i} = "import fake"\ndef f{i}():\n    return {i}\n')
        elif language == 'go':
            out.append(f'// import "fake"\nvar s{i} = "import \\"x\\""\n\nfunc f{i}() int {{ return {i} }}\n')
        elif language == 'rust':
            out.append(f'use crate::m{i}::Item{i};\n// use fake::x;\nconst S{i}: &str = "use x::y;";\nfn f{i}() -> u32 {{ {i} }}\n')
        elif language == 'nim':
            out.append(f'import m{i}\n# import fake\nlet s{i} = "import x"\nproc f{i}(): int = {i}\n')
        elif language == 'java':
            out.append(f'    // import fake.Thing;\n    String s{i} = "import x.y;";\n    int f{i}() {{ return {i}; }}\n')
    if language == 'java':
        out.append('}\n')
    return ''.join(out)


def kinds(n):
    """TypeScript with each import kind: one static, five type-only, one
    dynamic, and a commented-out import, per unit."""
    return ''.join(
        f"import {{ a{i} }} from './m{i}';\nimport type {{ T{i} }} from './t{i}';\nexport type {{ U{i} }} from './u{i}';\n"
        f"import {{ type V{i}, type W{i} }} from './v{i}';\nconst d{i} = import('./d{i}');\nlet x{i}: import('./x{i}').X;\n"
        f"type Y{i} = typeof import('./y{i}');\n// import type {{ Z }} from './fake'\n" for i in range(n))


def manifest(name, n):
    r = range(n)
    if name == 'package.json':
        deps = ',\n'.join(f'    "d{i}": "^1.{i}.0"' for i in r)
        return '{\n  "name": "bench",\n  "version": "1.0.0",\n  "dependencies": {\n' + deps + '\n  }\n}\n'
    if name == 'Cargo.toml':
        return '[package]\nname = "bench"\nversion = "0.1.0"\n\n[dependencies]\n' + ''.join(f'd{i} = "1.{i}"\n' for i in r)
    if name == 'pyproject.toml':
        return '[project]\nname = "bench"\nversion = "1.0"\ndependencies = [\n' + ''.join(f'    "d{i}>=1.{i}",\n' for i in r) + ']\n'
    if name == 'go.mod':
        return 'module example.com/bench\n\ngo 1.22\n\nrequire (\n' + ''.join(f'\texample.com/d{i} v1.{i}.0\n' for i in r) + ')\n'
    if name == 'build.zig.zon':
        deps = ''.join(f'        .d{i} = .{{\n            .url = "https://example.com/d{i}.tar.gz",\n            .hash = "d{i}-1.0.0-AAAAAAAA",\n        }},\n' for i in r)
        return '.{\n    .name = .bench,\n    .version = "0.0.0",\n    .fingerprint = 0x1234567890abcdef,\n    .dependencies = .{\n' + deps + '    },\n    .paths = .{""},\n}\n'
    if name == 'pom.xml':
        deps = ''.join(f'    <dependency>\n      <groupId>org.d{i}</groupId>\n      <artifactId>d{i}</artifactId>\n      <version>1.{i}</version>\n    </dependency>\n' for i in r)
        return ('<?xml version="1.0" encoding="UTF-8"?>\n<project>\n  <modelVersion>4.0.0</modelVersion>\n  <groupId>org.bench</groupId>\n'
                '  <artifactId>bench</artifactId>\n  <version>1.0</version>\n  <dependencies>\n' + deps + '  </dependencies>\n</project>\n')
    if name == 'build.gradle':
        return "plugins {\n    id 'java'\n}\n\ndependencies {\n" + ''.join(f"    implementation 'org.d{i}:d{i}:1.{i}'\n" for i in r) + '}\n'
    if name == 'bench.nimble':
        return 'version = "1.0.0"\nauthor = "bench"\n\n' + ''.join(f'requires "d{i} >= 1.{i}"\n' for i in r)
    raise ValueError(name)


def markdown(root, count, write):
    """count pages in groups of ten; five sibling links each, plus links in
    fenced code and comments that are not links."""
    for i in range(count):
        g, m = divmod(i, 10)
        links = ''.join(f'See [page {k}](m{(m + k) % 10}.md) and read on.\n' for k in range(1, 6))
        text = f'# Page {i}\n\n' + 'comment ' * 16 + '\n\n' + links + '\n```\n[not a link](m0.md)\n```\n\n<!-- [hidden](m1.md) -->\n'
        write(root / f'd{g}/m{m}.md', text)


def python_package(root, count, write):
    """An importable package for import-linter: pkg.gN.fM imports pkg.gN.f(M-1)."""
    write(root / 'pkg/__init__.py', '')
    for i in range(count):
        g, m = divmod(i, 10)
        if m == 0:
            write(root / f'pkg/g{g}/__init__.py', '')
        body = f'import pkg.g{g}.f{max(0, m - 1)}\n' if m else ''
        write(root / f'pkg/g{g}/f{m}.py', body + '# ' + 'comment ' * 16 + '\ntext = "import pkg.fake"\n')


def typescript_tree(root, count, write):
    """js/gN/fM.ts imports the file before it in its folder, and each f0 the
    f5 of folder (N - 1) / 2: dependencies inside and across folders, in
    chains no deeper than a balanced tree (dependency-cruiser's recursive
    cycle search exhausts node's stack on a chain of hundreds of folders)."""
    for i in range(count):
        g, m = divmod(i, 10)
        body = f"import './f{m - 1}';\n" if m else (f"import '../g{(g - 1) // 2}/f5';\n" if g else '')
        write(root / f'js/g{g}/f{m}.ts', body + '// ' + 'comment ' * 16 + "\nexport const text = \"import './fake'\";\n")


def save(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists() or path.read_text() != text:
        path.write_text(text)


def generate(root, smoke, write=True):
    """Returns {(kind, name, size): path}; smoke keeps only the small size.
    Without write, only the paths: the quiet pass reads what preparation wrote."""
    root = Path(root)
    write = save if write else (lambda path, text: None)
    files = {}
    for language, ext in EXTENSIONS.items():
        for size, n in IMPORT_SIZES.items():
            if smoke and size != 'small': continue
            path = root / 'imports' / language / (size + ext)
            if language == 'java':
                path = root / 'imports' / language / size / 'Big.java'
            write(path, source(language, n))
            files[('imports', language, size)] = path
    for size, n in IMPORT_SIZES.items():
        if smoke and size != 'small': continue
        path = root / 'kinds' / 'javascript' / (size + '.ts')
        write(path, kinds(n))
        files[('kinds', 'javascript', size)] = path
    for name in MANIFESTS:
        for size, n in MANIFEST_SIZES.items():
            if smoke and size != 'small': continue
            path = root / 'manifests' / size / name
            write(path, manifest(name, n))
            files[('manifests', name, size)] = path
    count = 10 if smoke else 5000
    markdown(root / 'markdown', count, write)
    python_package(root / 'python', count, write)
    typescript_tree(root / 'typescript', 30 if smoke else 5000, write)
    write(root / 'python.importlinter', '[importlinter]\nroot_package = pkg\n\n[importlinter:contract:forbid]\nname = forbid\n'
          'type = forbidden\nsource_modules =\n    pkg.*.f5\nforbidden_modules =\n    pkg.*.f4\nallow_indirect_imports = True\n')
    write(root / 'python-reach.importlinter', '[importlinter]\nroot_package = pkg\n\n[importlinter:contract:far]\nname = far\n'
          'type = forbidden\nsource_modules =\n    pkg.*.f9\nforbidden_modules =\n    pkg.*.f1\n')
    return files
