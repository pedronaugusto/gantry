"""Every public gantry operation: in-process workloads on both revisions, and
the standard tool that offers the same operation, on the same input.

Each workload's sides must report the same counts (and the same source
bytes for per-file workloads), or the pass fails. A side without an
equivalent operation gets one `unavailable` row with its reason."""
import json
import fixtures
from quiet_common import tsv

SIZES = ('small', 'medium', 'large')
NO_TOOL_GRAPH = 'no pinned tool takes a caller edge list: madge --circular and import-linter analyse only graphs they build'
NO_TOOL_MATCH = 'the pinned tools offer path globs only inside interpreters (minimatch, pathlib), where one call costs more than the match'
UNAVAILABLE = {
    'rules/transitive': 'dependency-cruiser and import-linter check only graphs they build; end to end in process/reach-js and process/reach-python',
    'imports/c': 'no include lister short of a preprocessor: cc -M and libclang evaluate conditionals and need every header present',
    'imports/nim': "Nim's parser ships only inside the compiler; nim genDepend compiles a whole project",
    'manifests/build.gradle': 'Gradle reads build scripts only by evaluating them in its daemon; there is no standalone declaration reader',
    'manifests/bench.nimble': 'nimble evaluates .nimble files as NimScript; there is no standalone declaration reader',
    'rules/ordered': 'dependency-cruiser and import-linter check only graphs they build; end to end in process/check-js and process/check-python',
    'scan/memory': 'no tool scans caller-held bytes; whole-tree scans are compared on real repositories (<language>/graph)',
    'scan/diagnostic': 'no tool scans caller-held bytes; whole-tree scans are compared on real repositories (<language>/graph)',
    'scan/links': 'compared end to end with markdown-it-py in process/links',
    'scan/assets': 'no pinned tool recovers asset paths from text files',
    'scan/tokens': 'compared end to end with ripgrep in process/tokens',
    'rules/tokens': 'compared end to end with ripgrep in process/tokens',
    'path/normalize': "posixpath.normpath and std.fs.path.resolve keep '..' above the root and accept absolute paths",
    'match/path': NO_TOOL_MATCH, 'match/token': NO_TOOL_MATCH,
}
UNAVAILABLE['rules/dependencies'] = ('dependency-cruiser no-non-package-json, depcheck and deptry judge packages resolved in an installed '
                                     'node_modules or environment; the bench installs none for its corpora')
UNAVAILABLE['rules/reachable'] = ("dependency-cruiser's reachable: false and madge --orphans check only graphs they build; "
                                  'unreached files are not compared end to end')
for family in ('forbidden', 'allowed', 'nothing-imports', 'references', 'required', 'cycles'):
    UNAVAILABLE['rules/' + family] = UNAVAILABLE['rules/ordered']
UNAVAILABLE['rules/layers-transitive'] = UNAVAILABLE['rules/transitive']
for op in ('from-edges', 'analysis-init', 'analyze', 'aggregate'):
    UNAVAILABLE['graph/' + op] = NO_TOOL_GRAPH


def alternatives(workload, arg, after, scratch, here, jdk):
    """(side, argv) for each tool offering the operation, on the same input."""
    alt, py, node = scratch / 'alt', [scratch / 'venv/bin/python', here / 'alt/alt.py', workload, arg], ['node', here / 'alt/alt.cjs', workload, scratch, arg]
    return {
        'imports/zig': [('zig-std-ast', [after / 'alt-zig', workload, arg])],
        'imports/javascript': [('typescript', node)],
        'imports/python': [('python-ast', py)],
        'imports/go': [('go-parser', [alt / 'alt-go', workload, arg])],
        'imports/rust': [('syn', [alt / 'alt-rust', workload, arg])],
        'imports/java': [('javac', [jdk / 'bin/java', '-cp', alt / 'java', 'Imports', workload, arg])],
        'manifests/package.json': [('python-json', py)],
        'manifests/Cargo.toml': [('python-tomllib', py)],
        'manifests/pyproject.toml': [('python-tomllib', py)],
        'manifests/pom.xml': [('python-elementtree', py)],
        'manifests/go.mod': [('x-mod-modfile', [alt / 'alt-go', workload, arg])],
        'manifests/build.zig.zon': [('zig-std-zon', [after / 'alt-zig', workload, arg])],
        'process/walk': [('find', ['find', arg, '-type', 'f']), ('ripgrep', [scratch / 'cargo/bin/rg', '--files', arg])],
        'process/check-js': [('dependency-cruiser', node)],
        'process/metrics-js': [('dependency-cruiser', node)],
        'process/reach-js': [('dependency-cruiser', node)],
        'process/reach-python': [('import-linter', py)],
        'process/type-checking-python': [('grimp', py)],
        'kinds/javascript': [('typescript', node)],
        'graph/direct': [('grimp', py)], 'graph/reach': [('grimp', py)],
        'graph/affected': [('grimp', py)], 'graph/chain': [('grimp', py)],
        'process/check-python': [('import-linter', py)],
        'process/links': [('markdown-it-py', py)],
        'process/tokens': [('ripgrep', [scratch / 'cargo/bin/rg', '--word-regexp', '--count-matches', 'Thing', arg])],
    }.get(workload, [])


def counts(workload, output):
    """Counts and source bytes, from bench rows or a plain tool's lines."""
    if '\t' in output:
        return {k: int(v) for k, v in tsv(output)['counts'].items()}
    lines = [line for line in output.splitlines() if line]
    if workload == 'process/walk':
        return {'files': len(lines)}
    if workload == 'process/tokens':
        return {'findings': sum(int(line.rpartition(':')[2]) for line in lines)}
    raise ValueError(f'{workload}: unexpected output')


def agreement(workload):
    reference = {}
    def check(output, side):
        found = counts(workload, output)
        if not found or not all(found.values()):
            raise ValueError(f'{workload}/{side}: empty result {found}')
        if not reference: reference.update(found)
        for key in reference.keys() & found.keys():
            if reference[key] != found[key]:
                raise ValueError(f'{workload}/{side}: {key} {found[key]}, other sides {reference[key]}')
        return found
    return check


def run(p, binary, scratch, env, jdk):
    """All per-operation workloads, after the synthetic scan and before the real repositories."""
    root = p.build / 'ops'
    files = fixtures.generate(root, p.smoke, write=p.preparing)
    p.prepared.require(root)
    for asset in ('alt/alt-go', 'alt/alt-rust', 'alt/java/Imports.class', 'cargo/bin/rg'):
        p.prepared.require(scratch / asset)
    env = {**env, **({'BENCH_SMOKE': '1'} if p.smoke else {})}
    env.pop('BENCH_PHASES', None)
    listed = {s: set(p.run([binary[s] / 'ops', '--list']).split()) for s in binary}
    corpus = {'process/walk': p.build / 'corpus', 'process/check-js': p.build / 'corpus', 'process/tokens': p.build / 'corpus',
              'process/metrics-js': root / 'typescript', 'process/reach-js': p.build / 'corpus',
              'process/check-python': root / 'python', 'process/reach-python': root / 'python', 'process/type-checking-python': root / 'typing', 'process/links': root / 'markdown'}
    for workload in sorted(listed['after'], key=lambda w: (w.startswith('process/'), w)):
        kind = workload.split('/')[0]
        if kind in ('imports', 'manifests', 'kinds'):
            name = workload.split('/', 1)[1]
            points = [(size, files[(kind, name, size)]) for size in SIZES if (kind, name, size) in files]
        elif kind == 'process':
            points = [(None, corpus[workload])]
        else:
            points = [(size, size) for size in (('small',) if p.smoke else SIZES)]
        if workload not in listed['before']:
            p.unavailable(workload, 'before', 'the before revision has no such operation')
        if workload in UNAVAILABLE:
            p.unavailable(workload, 'alternatives', UNAVAILABLE[workload])
        for size, arg in points:
            label = workload if size is None else f'{workload}/{size}'
            commands = [(s, [binary[s] / 'ops', workload, arg]) for s in ('before', 'after') if workload in listed[s]]
            commands += alternatives(workload, arg, binary['after'], scratch, p.here, jdk)
            # Whole-tree workloads compare processes; per-file ones time inside each process.
            p.interleave(label, commands, env=env, check=agreement(label), wall=kind == 'process')


def phases(stderr_file):
    """PHASE lines a comparison wrote to stderr, in milliseconds."""
    if not stderr_file.exists(): return None
    found = {}
    for line in stderr_file.read_text().splitlines():
        if line.startswith('PHASE\t'):
            _, name, ms = line.split('\t')
            found[name] = float(ms)
    return found or None


def cargo_metadata(output, side):
    packages = json.JSONDecoder().raw_decode(output.lstrip())[0]['packages']
    if not packages: raise ValueError('cargo metadata listed no packages')
    return {'packages': len(packages)}
