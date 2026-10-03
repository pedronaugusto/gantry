"""Python-side comparisons, with the same output rows as bench/ops.

Per-file workloads repeat for 200 ms after one warm-up, inside the process;
whole-tree workloads run once and report their phases, so interpreter start
and imports stay apart from the analysis."""
import time
T0 = time.perf_counter()
import ast
import io
import json
import os
import re
import sys
import tomllib
import xml.etree.ElementTree as ElementTree
from contextlib import redirect_stdout
from pathlib import Path

SMOKE = bool(os.environ.get('BENCH_SMOKE'))


def row(side, workload, metric, value, unit):
    print(f'{side}\t{workload}\t{metric}\t{value}\t{unit}', flush=True)


def repeat(side, workload, op, data, metric):
    count = op(data)
    if SMOKE:
        row(side, workload, 'ns_per_op', 0, 'ns')
    else:
        iterations, start = 0, time.perf_counter_ns()
        while iterations < 3 or time.perf_counter_ns() - start < 200_000_000:
            count = op(data)
            iterations += 1
        row(side, workload, 'ns_per_op', f'{(time.perf_counter_ns() - start) / iterations:.3f}', 'ns')
        row(side, workload, 'iterations', iterations, 'iterations')
    row(side, workload, 'source', len(data), 'bytes')
    row(side, workload, metric, count, 'count')


def python_imports(data):
    # ast.parse is CPython's own parser: a complete syntax tree per file.
    return sum(len(n.names) if isinstance(n, ast.Import) else 1
               for n in ast.walk(ast.parse(data)) if isinstance(n, (ast.Import, ast.ImportFrom)))


GROUPS = {'package.json': ('dependencies', 'devDependencies', 'peerDependencies', 'optionalDependencies'),
          'Cargo.toml': ('dependencies', 'dev-dependencies', 'build-dependencies')}


def package_json(data):
    value = json.loads(data)
    return sum(len(value.get(g, {})) for g in GROUPS['package.json'])


def cargo_toml(data):
    value = tomllib.loads(data.decode())
    return sum(len(value.get(g, {})) for g in GROUPS['Cargo.toml'])


def pyproject_toml(data):
    project = tomllib.loads(data.decode()).get('project', {})
    return len(project.get('dependencies', [])) + sum(map(len, project.get('optional-dependencies', {}).values()))


def pom_xml(data):
    root = ElementTree.fromstring(data)
    ns = root.tag[:root.tag.index('}') + 1] if root.tag.startswith('{') else ''
    return len(root.findall(f'{ns}dependencies/{ns}dependency'))


MANIFESTS = {'package.json': ('python-json', package_json), 'Cargo.toml': ('python-tomllib', cargo_toml),
             'pyproject.toml': ('python-tomllib', pyproject_toml), 'pom.xml': ('python-elementtree', pom_xml)}


def links(workload, root):
    """markdown-it-py (CommonMark) parses each page; relative links to
    existing pages count once per (page, target), as gantry's link edges."""
    loaded = time.perf_counter()
    from markdown_it import MarkdownIt
    md = MarkdownIt('commonmark')
    imported = time.perf_counter()
    root = Path(root)
    pages = sorted(p for p in root.rglob('*.md'))
    names = {p.relative_to(root).as_posix() for p in pages}
    edges = set()
    for page in pages:
        source = page.relative_to(root).as_posix()
        for token in md.parse(page.read_text()):
            for child in token.children or ():
                href = child.attrs.get('href') if child.type == 'link_open' else None
                if href and '://' not in href:
                    target = os.path.normpath(os.path.join(os.path.dirname(source), href))
                    if target in names and target != source:
                        edges.add((source, target))
    done = time.perf_counter()
    phases('markdown-it-py', workload, loaded, imported, done)
    row('markdown-it-py', workload, 'files', len(pages), 'count')
    row('markdown-it-py', workload, 'links', len(edges), 'count')


def importlinter(workload, root):
    """import-linter's forbidden contract, direct imports only, no cache."""
    # The contract is written beside the package by bench/fixtures.py.
    config = Path(root).parent / 'python.importlinter'
    loaded = time.perf_counter()
    sys.path.insert(0, str(root))
    from importlinter.cli import lint_imports
    imported = time.perf_counter()
    report = io.StringIO()
    with redirect_stdout(report):
        lint_imports(config_filename=str(config), no_cache=True, no_logo=True)
    done = time.perf_counter()
    text = re.sub(r'\x1b\[[0-9;?]*[A-Za-z]', '', report.getvalue())
    broken = set(re.findall(r'^-\s+(pkg\.\S+) -> (pkg\.\S+) \(l\.', text, re.M))
    if not broken and 'BROKEN' in text:
        raise SystemExit('import-linter output changed shape:\n' + report.getvalue())
    phases('import-linter', workload, loaded, imported, done)
    row('import-linter', workload, 'findings', len(broken), 'count')


SIZES = {'small': 100, 'medium': 5_000, 'large': 50_000}


def grimp_query(workload, size):
    """Grimp's own graph (Rust), built from bench/ops's in-memory corpus
    edges outside the clock: groups of ten in a cycle, each group's f0
    importing the previous group's f5. The query alone is timed."""
    import grimp
    n = SIZES[size]
    graph = grimp.ImportGraph()
    edges = 0
    for i in range(n):
        g, m = divmod(i, 10)
        graph.add_import(importer=f'g{g}.f{m}', imported=f'g{g}.f{9 if m == 0 else m - 1}')
        edges += 1
        if m == 0 and g > 0:
            graph.add_import(importer=f'g{g}.f0', imported=f'g{g - 1}.f5')
            edges += 1
    last = f'g{n // 10 - 1}.f0'
    # gantry lists a start a chain returns to; every start here sits on its
    # group's cycle, and Grimp's sets leave the module out, so it counts once
    # more (without copying the set).
    def plus(found, start):
        return len(found) + (start not in found)
    ops = {
        'graph/direct': lambda _: len(graph.find_modules_that_directly_import('g0.f5')),
        'graph/reach': lambda _: plus(graph.find_upstream_modules(last), last),
        'graph/affected': lambda _: plus(graph.find_downstream_modules('g0.f0'), 'g0.f0'),
        'graph/chain': lambda _: len(graph.find_shortest_chain(last, 'g0.f1')),
    }
    metric = workload.removeprefix('graph/')
    count = ops[workload](None)
    if SMOKE:
        row('grimp', workload, 'ns_per_op', 0, 'ns')
    else:
        iterations, start = 0, time.perf_counter_ns()
        while iterations < 3 or time.perf_counter_ns() - start < 200_000_000:
            count = ops[workload](None)
            iterations += 1
        row('grimp', workload, 'ns_per_op', f'{(time.perf_counter_ns() - start) / iterations:.3f}', 'ns')
        row('grimp', workload, 'iterations', iterations, 'iterations')
    row('grimp', workload, 'files', n, 'count')
    row('grimp', workload, 'input_edges', edges, 'count')
    row('grimp', workload, metric, count, 'count')


def importlinter_reach(workload, root):
    """import-linter's forbidden contract with indirect imports: every
    source module that a chain leads to a forbidden one, no cache."""
    config = Path(root).parent / 'python-reach.importlinter'
    loaded = time.perf_counter()
    sys.path.insert(0, str(root))
    from importlinter.cli import lint_imports
    imported = time.perf_counter()
    report = io.StringIO()
    with redirect_stdout(report):
        lint_imports(config_filename=str(config), no_cache=True, no_logo=True)
    done = time.perf_counter()
    text = re.sub(r'\x1b\[[0-9;?]*[A-Za-z]', '', report.getvalue())
    sources = set(re.findall(r'^(pkg\.\S+) is not allowed to import (?:pkg\.\S+):', text, re.M))
    if not sources and 'BROKEN' in text:
        raise SystemExit('import-linter output changed shape:\n' + report.getvalue())
    phases('import-linter', workload, loaded, imported, done)
    row('import-linter', workload, 'findings', len(sources), 'count')


def phases(side, workload, loaded, imported, done):
    # Interpreter start until this script ran is the remainder of the outer wall time.
    if SMOKE: return
    row(side, workload, 'script_ms', f'{(loaded - T0) * 1000:.3f}', 'ms')
    row(side, workload, 'import_ms', f'{(imported - loaded) * 1000:.3f}', 'ms')
    row(side, workload, 'analysis_ms', f'{(done - imported) * 1000:.3f}', 'ms')


def main():
    workload, arg = sys.argv[1:]
    if workload == 'imports/python':
        repeat('python-ast', workload, python_imports, Path(arg).read_bytes(), 'imports')
    elif workload.startswith('manifests/'):
        side, op = MANIFESTS[workload.removeprefix('manifests/')]
        repeat(side, workload, op, Path(arg).read_bytes(), 'dependencies')
    elif workload == 'process/links':
        links(workload, arg)
    elif workload == 'process/check-python':
        importlinter(workload, arg)
    elif workload == 'process/reach-python':
        importlinter_reach(workload, arg)
    elif workload in ('graph/direct', 'graph/reach', 'graph/affected', 'graph/chain'):
        grimp_query(workload, arg)
    else:
        raise SystemExit(f'unknown workload {workload}')


if __name__ == '__main__':
    main()
