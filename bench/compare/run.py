"""Real graph agreement and optional interleaved warm process measurements."""
import argparse
from collections import Counter, defaultdict
from functools import cache
import json
import os
import posixpath
from pathlib import Path
import re
import statistics
import subprocess
import sys
import tempfile
import time

from setup import HERE, PINS, environment, prepare, verify_tools


def command(argv, cwd, env, output, timed=False):
    """wait4 measures this child only, including its terminated descendants."""
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("wb") as stdout, output.with_suffix(output.suffix + ".stderr").open("wb") as stderr:
        start = time.perf_counter() if timed else None
        process = subprocess.Popen(list(map(str, argv)), cwd=cwd, env=env, stdout=stdout, stderr=stderr)
        _, status, usage = os.wait4(process.pid, 0)
        process.returncode = os.waitstatus_to_exitcode(status)
        elapsed = time.perf_counter() - start if timed else None
    if process.returncode:
        raise RuntimeError(f"{argv} exited {process.returncode}: {output.with_suffix(output.suffix + '.stderr')}")
    if timed:
        # Darwin ru_maxrss is bytes, Linux is KiB; process-tree memory is not a summed simultaneous peak.
        rss = usage.ru_maxrss if sys.platform == "darwin" else usage.ru_maxrss * 1024
        return {"wall_seconds": elapsed, "peak_rss_bytes": rss}


def tracked(repo):
    return subprocess.check_output(["git", "-C", str(repo), "ls-files", "-z"], text=True).split("\0")[:-1]


def json_stream(text):
    decoder = json.JSONDecoder()
    pos = 0
    while pos < len(text):
        if text[pos].isspace():
            pos += 1
            continue
        item, pos = decoder.raw_decode(text, pos)
        yield item


def module_file(name, files):
    path = name.replace(".", "/")
    for candidate in [path + ".py", path + "/__init__.py"]:
        if candidate in files:
            return candidate


def rust_module(path, scope):
    rel = Path(path).relative_to(scope).as_posix()[:-3]
    if rel in ("lib", "main"):
        return "ide"
    if rel.endswith("/mod"):
        rel = rel[:-4]
    return "ide::" + rel.replace("/", "::")


def rust_dot(text, files, scope):
    # cargo-modules uses quoted full Rust paths as DOT node IDs. Project items
    # and inline modules to the longest file-module prefix in the selected crate.
    modules = {rust_module(p, scope): p for p in files if p.endswith(".rs")}
    def owner(node):
        while node:
            if node in modules:
                return node
            node = node.rpartition("::")[0]
    edges = set()
    for source, target in re.findall(r'"([^"\n]+)"\s*->\s*"([^"\n]+)"', text):
        source, target = owner(source), owner(target)
        if source and target and source != target:
            edges.add((source, target))
    if not edges:
        raise ValueError("cargo-modules produced no normalized edges; check DOT adapter")
    return edges


def normalise(tool, output, repo, files, scope, go_packages):
    text = output.read_text()
    if tool == "gantry":
        edges = {tuple(line.split("\t")[1:3]) for line in text.splitlines() if line.startswith("E\t")}
        if scope.startswith("crates/"):
            return {(rust_module(a, scope), rust_module(b, scope)) for a, b in edges if a != b}
        if go_packages is not None:
            return {(Path(a).parent.as_posix(), Path(b).parent.as_posix()) for a, b in edges
                    if a.startswith(scope + "/") and Path(a).parent != Path(b).parent}
        return edges
    if tool == "cargo-modules":
        return rust_dot(text, files, scope)
    if tool == "go-list":
        packages = list(json_stream(text))
        if any(p.get("Error") or p.get("DepsErrors") for p in packages):
            raise ValueError("go list reported incomplete packages")
        return {(go_packages[p["ImportPath"]], go_packages[d]) for p in packages
                if p["ImportPath"] in go_packages and go_packages[p["ImportPath"]].startswith(scope + "/")
                for d in p.get("Imports", []) if d in go_packages and go_packages[p["ImportPath"]] != go_packages[d]}
    data = json.loads(text)
    if tool in ("grimp", "pydeps"):
        pairs = data["edges"] if tool == "grimp" else [(p["name"], d) for p in data.values() for d in p.get("imports", [])]
        return {(a, b) for source, target in pairs if (a := module_file(source, files)) and (b := module_file(target, files))}
    if tool == "madge":
        pairs = [(a, b) for a, deps in data["graph"].items() for b in deps]
    else:
        pairs = [(m["source"], d["resolved"]) for m in data["modules"] for d in m["dependencies"] if not d.get("couldNotResolve")]
    def relative(p):
        path = Path(p)
        if path.is_absolute():
            try:
                return path.relative_to(repo).as_posix()
            except ValueError:
                return None
        return path.as_posix().removeprefix("./")
    return {(a, b) for source, target in pairs if (a := relative(source)) in files and (b := relative(target)) in files}


def make_case(language, scratch, out, env, binary, smoke):
    pin = PINS["repositories"][language]
    repo = scratch / "repos" / language
    actual = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
    if actual != pin["commit"] or subprocess.check_output(["git", "-C", str(repo), "diff", "HEAD", "--name-only"]):
        raise ValueError(f"corpus differs from pinned commit: {repo}")
    scope = ({"typescript":"src/vs/base/common", "python":"django/utils", "go":"pkg/util/slice", "rust":pin["scope"], "zig":"lib/std/Random"}[language]) if smoke else pin["scope"]
    suffix = {"typescript": (".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".mts", ".cts"), "python": (".py",), "go": (".go",), "rust": (".rs",), "zig": (".zig",)}[language]
    files = {p for p in tracked(repo) if p.startswith(scope + "/") and p.endswith(suffix)}
    go_packages = None
    commands = {}
    if smoke and language == "rust":
        files = {p for p in files if Path(p).name in ("lib.rs", "file_structure.rs", "runnables.rs", "hover.rs")}
    if language == "go":
        env["GOWORK"] = str(repo / "go.work")
        argv = ["go", "list", "-mod=vendor", "-deps", "-json", "./pkg/util/slice" if smoke else "./pkg/..."]
        discovery = out / "go-discovery.json"
        command(argv, repo, env, discovery)
        packages = list(json_stream(discovery.read_text()))
        go_packages = {}
        for p in packages:
            if p.get("Error") or p.get("DepsErrors"):
                raise ValueError(f"incomplete Go package {p['ImportPath']}")
            try:
                rel = Path(p["Dir"]).relative_to(repo).as_posix()
            except ValueError:
                continue
            if not rel.startswith("vendor/"):
                go_packages[p["ImportPath"]] = rel
        dirs = set(go_packages.values())
        files = {p for p in tracked(repo) if (p.endswith(".go") and Path(p).parent.as_posix() in dirs) or p.endswith("go.mod")}
        commands["go-list"] = argv
    elif language == "typescript":
        commands = {tool: ["node", HERE / "typescript.cjs", tool, scratch, repo, scope] for tool in ("madge", "dependency-cruiser")}
    elif language == "python":
        commands = {"pydeps": [scratch / "venv/bin/pydeps", "django", "--no-config", "--show-deps", "--no-show", "--no-output", "--max-bacon=0"],
                    "grimp": [scratch / "venv/bin/python", HERE / "python_graph.py", repo]}
    elif language == "rust":
        commands = {"cargo-modules": [scratch / "cargo/bin/cargo-modules", "dependencies", "--lib", "--package", pin["package"], "--no-externs", "--no-sysroot"]}
    listing = out / "paths.txt"
    listing.parent.mkdir(parents=True, exist_ok=True)
    listing.write_text("\n".join(sorted(files)) + "\n")
    commands = {"gantry": [binary, repo, listing], **commands}
    return repo, scope, files, commands, go_packages


@cache
def witnesses(folder, repo, scope):
    refs, contributors, active, rust = defaultdict(list), defaultdict(set), defaultdict(set), defaultdict(list)
    with (folder / "gantry.raw").open() as raw:
        for line in raw:
            if line.startswith("R\t"):
                fields = line.rstrip("\n").split("\t", 4)
                refs[fields[1]].append(fields[4])
            elif line.startswith("E\t"):
                _, source, target = line.rstrip("\n").split("\t")
                contributors[(Path(source).parent.as_posix(), Path(target).parent.as_posix())].add(source)
    if (folder / "go-list.raw").exists():
        for package in json_stream((folder / "go-list.raw").read_text()):
            try:
                rel = Path(package["Dir"]).relative_to(repo).as_posix()
            except ValueError:
                continue
            active[rel].update(rel + "/" + f for f in package.get("GoFiles", []) + package.get("CgoFiles", []))
    if (folder / "cargo-modules.raw").exists():
        modules = {rust_module(p, scope) for p in (folder / "paths.txt").read_text().splitlines()}
        def owner(node):
            while node:
                if node in modules:
                    return node
                node = node.rpartition("::")[0]
        for line in (folder / "cargo-modules.raw").read_text().splitlines():
            if pair := re.search(r'"([^"\n]+)"\s*->\s*"([^"\n]+)"', line):
                rust[(owner(pair[1]), owner(pair[2]))].append(line.strip())
    return refs, contributors, active, rust


def classify(language, direction, edge, repo, folder, graphs, scope):
    """Use witnesses to separate documented scope from differences needing review."""
    a, b = edge
    evidence = []
    refs_by_source, go_contributors, go_active, rust_witnesses = witnesses(folder, repo, scope)
    if language == "typescript":
        refs = refs_by_source[a]
        if direction == "gantry_only" and b.endswith(".js") and (a, b[:-3] + ".d.ts") in graphs["madge"]:
            return "scope: gantry chooses exact runtime .js; madge chooses its .d.ts declaration", [b[:-3] + ".d.ts"]
        for ref in refs:
            candidate = posixpath.normpath(posixpath.join(posixpath.dirname(a), ref))
            if direction == "rival_only" and b.endswith(".d.ts") and ref.startswith(".") and b in (candidate + ".d.ts", candidate.removesuffix(".js") + ".d.ts"):
                return "scope: declaration-file resolution is outside gantry's documented suffix order", [ref]
            candidate = "src/" + ref
            if direction == "rival_only" and ref.startswith("vs/") and b in (candidate, candidate + ".ts", candidate.removesuffix(".js") + ".ts"):
                return "scope: tsconfig baseUrl aliases are not resolved by gantry", [ref]
        return "review: relative import extraction or rival omission", refs
    if language == "python":
        if direction == "gantry_only" and b.endswith("/__init__.py"):
            return "scope: gantry includes selected ancestor/package initializers", [b]
        if direction == "gantry_only" and "/migrations/" in a:
            return "rival limit: pydeps skips migrations when constructing its dummy entry module", [a]
        if direction == "rival_only" and b.endswith("/__init__.py"):
            return "scope: pydeps modulefinder records additional ancestors of relative imports", [b]
        if direction == "rival_only" and a == "django/db/migrations/__init__.py":
            return "scope: pydeps follows star re-exported symbols; gantry records the literal imported module", ["from .operations import *"]
        return "review: Python statement extraction or rival import interpretation", evidence
    if language == "go":
        if direction == "rival_only" and b.startswith("staging/"):
            return "scope: go.mod replacements/workspace modules are not resolved by gantry", [b]
        if direction == "gantry_only":
            contributors = go_contributors[(a, b)]
            active = go_active[a]
            if set(contributors) & active:
                return "review: import found in a compiler-selected Go file", sorted(set(contributors) & active)
            if contributors:
                reason = "scope: test files are selected by gantry and excluded by go list" if all(p.endswith("_test.go") for p in contributors) else "scope: build/platform variants excluded by go list are selected by gantry"
                return reason, sorted(set(contributors))
        return "review: Go package selection or resolution", evidence
    if language == "rust":
        if direction == "gantry_only" and any(p == "ide::fixture" or p.endswith("::tests") for p in edge):
            return "scope: test modules are selected by gantry and excluded by cargo-modules cfg", list(edge)
        if direction == "rival_only":
            if rust_witnesses[(a, b)]:
                return "scope: semantic definitions, re-exports and type dependencies are outside gantry resolution", rust_witnesses[(a, b)]
        return "review: Rust lexical resolution or cfg selection", evidence
    return "review: unexplained difference", evidence


def portable(value, scratch, source):
    if isinstance(value, dict): return {k:portable(v,scratch,source) for k,v in value.items()}
    if isinstance(value, list): return [portable(v,scratch,source) for v in value]
    if isinstance(value, str):
        return value.replace(str(source),"<source>").replace(str(HERE),"<harness>").replace(str(scratch),"<scratch>").replace(str(Path.home()),"<home>")
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scratch", type=Path, default=Path(tempfile.gettempdir()) / "gantry-compare")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--languages", nargs="+", choices=list(PINS["repositories"]), default=list(PINS["repositories"]))
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--agreement-only", action="store_true", help="run each graph once, record no measurements")
    parser.add_argument("--smoke", action="store_true", help="Tiny selections in every language; record no timings")
    parser.add_argument("--skip-setup", action="store_true")
    parser.add_argument("--gantry-source", type=Path, default=HERE.parent.parent)
    args = parser.parse_args()
    if args.runs < 1:
        parser.error("--runs must be positive")
    if args.smoke:
        args.runs = 1
        args.agreement_only = True
    scratch = args.scratch.resolve()
    out = (args.output or scratch / ("smoke" if args.smoke else "agreement" if args.agreement_only else "results")).resolve()
    out.mkdir(parents=True, exist_ok=True)
    env = environment(scratch) if args.skip_setup else prepare(scratch, args.languages)
    versions = verify_tools(scratch, args.languages, env)
    source = args.gantry_source.resolve()
    subprocess.run(["zig", "build", "compare", "-Doptimize=ReleaseFast", "--prefix", str(scratch / "gantry")], cwd=source, env=env, check=True)
    binary = scratch / "gantry/bin/compare-scan"
    summary = {"mode": "smoke" if args.smoke else "agreement" if args.agreement_only else "benchmark", "pins": PINS,
               "gantry_commit": subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip(),
               "gantry_dirty": bool(subprocess.check_output(["git", "-C", str(source), "status", "--porcelain"], text=True)),
               "gantry_source_tree": subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD:src"], text=True).strip(),
               "platform": sys.platform, "languages": {}, "rival_versions": versions, "runtime_versions": {"python": sys.version.split()[0]}}
    for name, argv in {"zig": ["zig", "version"], "go": ["go", "version"], "rust": ["rustc", "--version"], "node": ["node", "--version"]}.items():
        if name in ("zig",) or {"go": "go", "rust": "rust", "node": "typescript"}.get(name) in args.languages:
            summary["runtime_versions"][name] = subprocess.check_output(argv, env=env, text=True).strip()
    for language in args.languages:
        print(f"Comparing {language}", flush=True)
        folder = out / language
        repo, scope, files, commands, go_packages = make_case(language, scratch, folder, env, binary, args.smoke)
        graphs, samples = {}, {tool: [] for tool in commands}
        for tool, argv in commands.items():
            print(f"  graph/warmup: {tool}", flush=True)
            output = folder / (tool + ".raw")
            command(argv, repo, env, output)
            graphs[tool] = normalise(tool, output, repo, files, scope, go_packages)
            (folder / (tool + ".edges.json")).write_text(json.dumps(sorted(graphs[tool]), indent=2) + "\n")
        if not args.agreement_only:
            tools = list(commands)
            for run in range(args.runs):
                order = tools[run % len(tools):] + tools[:run % len(tools)]
                for tool in order:
                    print(f"  run {run + 1}: {tool}", flush=True)
                    output = folder / f"{tool}.run-{run + 1}.raw"
                    measured = command(commands[tool], repo, env, output, timed=True)
                    if normalise(tool, output, repo, files, scope, go_packages) != graphs[tool]:
                        raise ValueError(f"unstable graph: {language}/{tool}")
                    samples[tool].append({"run": run + 1, **measured})
        result = {"scope": scope, "selected_files": len(files), "gantry_edges": len(graphs["gantry"]), "gantry_sample": sorted(graphs["gantry"])[:5],
                  "commands": {k: list(map(str, v)) for k, v in commands.items()}, "agreement": {}, "measurements": samples}
        for rival, graph in graphs.items():
            if rival == "gantry":
                continue
            groups = {"agreed": graphs["gantry"] & graph, "gantry_only": graphs["gantry"] - graph, "rival_only": graph - graphs["gantry"]}
            result["agreement"][rival] = {}
            differences = []
            for name, edges in groups.items():
                result["agreement"][rival][name] = {"count": len(edges), "sample": sorted(edges)[:5]}
                for edge in sorted(edges):
                    if name != "agreed":
                        reason, evidence = classify(language, name, edge, repo, folder, graphs, scope)
                        differences.append({"class": name, "edge": edge, "reason": reason, "evidence": evidence})
            (folder / (rival + ".differences.json")).write_text(json.dumps(differences, indent=2) + "\n")
            result["agreement"][rival]["reasons"] = dict(Counter(d["reason"] for d in differences))
            result["agreement"][rival]["review_required"] = sum(d["reason"].startswith("review:") for d in differences)
        summary["languages"][language] = result
        (out / "report.json").write_text(json.dumps(portable(summary, scratch, source), indent=2) + "\n")
        witnesses.cache_clear()
    markdown(summary, out)
    print(f"Report: {out / 'report.md'}", flush=True)


def markdown(summary, out):
    lines = [f"# Edge agreement ({summary['mode']})", "", f"Gantry: `{summary['gantry_commit']}` (dirty: {summary['gantry_dirty']}).", "",
             "| Language / rival | Agreed | Gantry only | Rival only |", "|---|---:|---:|---:|"]
    for lang, result in summary["languages"].items():
        if not result["agreement"]:
            lines.append(f"| {lang} / none | — | {result['gantry_edges']} total edges | — |")
        for rival, agreement in result["agreement"].items():
            lines.append(f"| {lang} / {rival} | {agreement['agreed']['count']} | {agreement['gantry_only']['count']} | {agreement['rival_only']['count']} |")
    for lang, result in summary["languages"].items():
        lines += ["", f"## {lang}", "", f"Scope: `{result['scope']}`, {result['selected_files']} selected files."]
        if not result["agreement"]:
            lines += ["", "Gantry edge sample:", ""]
            lines.extend(f"- `{a}` → `{b}`" for a, b in result["gantry_sample"])
        for rival, agreement in result["agreement"].items():
            lines += ["", f"### {rival}", ""]
            for group in ("agreed", "gantry_only", "rival_only"):
                lines.extend([f"{group}: {agreement[group]['count']}; sample:", ""])
                lines.extend(f"- `{a}` → `{b}`" for a, b in agreement[group]["sample"])
                lines.append("")
            lines.extend(f"- {reason}: {count}" for reason, count in agreement["reasons"].items())
            lines += ["", f"Unexplained edges requiring review: {agreement['review_required']}."]
        if summary["mode"] == "benchmark":
            lines += ["", "| Tool | Wall median (s) | Peak RSS median (MiB) |", "|---|---:|---:|"]
            for tool, values in result["measurements"].items():
                lines.append(f"| {tool} | {statistics.median(x['wall_seconds'] for x in values):.3f} | {statistics.median(x['peak_rss_bytes'] for x in values) / 2**20:.1f} |")
    if summary["mode"] != "benchmark":
        lines += ["", "No benchmark timings. Smoke samples prove instrumentation only."]
    (out / "report.md").write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
