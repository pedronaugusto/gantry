"""Small format checks: catch direction errors, external leakage and item collapse."""
import json
from pathlib import Path
import tempfile
import unittest

import run
from run import java_classes, json_stream, nim_dot, nim_statement, nim_target, normalise, rust_dot, typescript_configs


class Adapters(unittest.TestCase):
    def test_go_stream_and_repository_packages(self):
        packages = [{"ImportPath": "k/pkg/a", "Imports": ["k/pkg/b", "fmt"]},
                    {"ImportPath": "k/pkg/b", "Imports": []}]
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "go.json"
            output.write_text("\n".join(map(json.dumps, packages)))
            self.assertEqual(list(json_stream(output.read_text())), packages)
            self.assertEqual(normalise("go-list", output, Path(directory), set(), "pkg", {"k/pkg/a": "pkg/a", "k/pkg/b": "pkg/b"}), {("pkg/a", "pkg/b")})

    def test_python_import_direction_and_initializer(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "py.json"
            output.write_text(json.dumps({"django.a": {"name": "django.a", "imports": ["django.b", "django", "os"]}}))
            files = {"django/a.py", "django/b.py", "django/__init__.py"}
            self.assertEqual(normalise("pydeps", output, Path(directory), files, "django", None), {("django/a.py", "django/b.py"), ("django/a.py", "django/__init__.py")})

    def test_rust_items_inline_modules_and_external_nodes(self):
        dot = '\n'.join(['"ide" -> "ide::hover" [label="owns"];',
                         '"ide::hover::inner::fn_name" -> "ide::markup::Markup" [label="uses"];',
                         '"ide::hover::one" -> "ide::hover::two";',
                         '"ide::hover" -> "std::fmt";'])
        files = {"crates/ide/src/lib.rs", "crates/ide/src/hover.rs", "crates/ide/src/markup.rs"}
        self.assertEqual(rust_dot(dot, files, "crates/ide/src"), {("ide", "ide::hover"), ("ide::hover", "ide::markup")})
        with self.assertRaises(ValueError):
            rust_dot('digraph {}', files, "crates/ide/src")

    def test_typescript_absolute_paths_and_unresolved_edges(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            output = repo / "ts.json"
            output.write_text(json.dumps({"modules": [{"source": "src/a.ts", "dependencies": [
                {"resolved": str(repo / "src/b.ts")}, {"resolved": "src/c.ts", "couldNotResolve": True}, {"resolved": "/outside/x.ts"}]}]}))
            self.assertEqual(normalise("dependency-cruiser", output, repo, {"src/a.ts", "src/b.ts", "src/c.ts"}, "src", None), {("src/a.ts", "src/b.ts")})

    def test_typescript_configs_that_apply_to_the_scope_and_their_local_bases(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            for name, text in {"src/tsconfig.json": '{ // own\n "extends": "./tsconfig.base.json"}',
                               "src/tsconfig.base.json": '{"extends": "../shared/base"}',
                               "shared/base.json": "{}",
                               "src/vs/jsconfig.json": "{}",
                               "src/tsconfig.monaco.json": "{}",
                               "extensions/tsconfig.json": "{}",
                               "src/vs/a.ts": ""}.items():
                (repo / name).parent.mkdir(parents=True, exist_ok=True)
                (repo / name).write_text(text)
            tracked = [p.relative_to(repo).as_posix() for p in repo.rglob("*") if p.is_file()]
            self.assertEqual(typescript_configs(repo, tracked, "src"), ["shared/base.json", "src/tsconfig.base.json", "src/tsconfig.json", "src/vs/jsconfig.json"])

    def test_gantry_config_nodes_stay_outside_the_source_universe(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "gantry.raw"
            output.write_text("E\tsrc/a.ts\tsrc/b.ts\nE\tsrc/tsconfig.json\tsrc/tsconfig.base.json\n")
            self.assertEqual(normalise("gantry", output, Path(directory), {"src/a.ts", "src/b.ts"}, "src", None), {("src/a.ts", "src/b.ts")})

    def test_typescript_declaration_beside_a_runtime_file_is_witnessed(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            (folder / "gantry.raw").write_text("R\tsrc/a.ts\t0\t1\t./lib/x.js\n")
            answers = {("src/a.ts", "./lib/x.js"): {"version": "5.7.3", "config": "src/tsconfig.json", "resolved": "src/lib/x.d.ts"}}
            original = run.typescript_resolution
            run.typescript_resolution = lambda repo, importer, specifier: answers[(importer, specifier)]
            try:
                for direction, target in (("gantry_only", "src/lib/x.d.ts"), ("rival_only", "src/lib/x.js")):
                    reason, witness = run.classify("typescript", direction, ("src/a.ts", target), folder, folder, {}, "src")
                    self.assertTrue(reason.startswith("scope: TypeScript resolves a `.js` specifier"), reason)
                    self.assertEqual(witness, ["./lib/x.js", "TypeScript 5.7.3 with src/tsconfig.json: src/lib/x.d.ts"])
                answers[("src/a.ts", "./lib/x.js")]["resolved"] = "src/lib/x.js"
                self.assertTrue(run.classify("typescript", "gantry_only", ("src/a.ts", "src/lib/x.d.ts"), folder, folder, {}, "src")[0].startswith("review:"))
            finally:
                run.typescript_resolution = original
                run.witnesses.cache_clear()

    def test_nim_modules_from_the_project_folder_and_outside_lib(self):
        dot = '\n'.join(['digraph nim {', '"nim" -> "ast";', '"ast" -> "std/os";', '"ic/ic" -> "../dist/x/y";', '"ic/ic" -> "ast";', '"ast" -> "ast";', '}'])
        files = {"compiler/nim.nim", "compiler/ast.nim", "compiler/ic/ic.nim"}
        nodes, edges = nim_dot(dot, files)
        self.assertEqual(edges, {("compiler/nim.nim", "compiler/ast.nim"), ("compiler/ic/ic.nim", "compiler/ast.nim")})
        self.assertEqual(nodes, files)
        with self.assertRaises(ValueError):
            nim_dot('digraph nim {}', files)

    def test_nim_witness_reads_includes_and_when_branches(self):
        text = "import a\ninclude b\nwhen defined(x):\n  # note\n  import c\n"
        self.assertEqual(nim_statement(text, text.index("include")), ("include", None))
        self.assertEqual(nim_statement(text, text.index("import c")), ("import", "when defined(x):"))
        files = {"compiler/a.nim", "compiler/x.inc"}
        self.assertEqual(nim_target("compiler/b.nim", "a", files), "compiler/a.nim")
        self.assertEqual(nim_target("compiler/b.nim", "x.inc", files), "compiler/x.inc")
        self.assertIsNone(nim_target("compiler/b.nim", "std/a", files))

    def test_java_classes_map_to_declaring_sources_without_self_edges(self):
        output = json.dumps({"jdeps": "\n".join(["classes -> java.base",
                                                   "   p.A          -> p.B          classes",
                                                   "   p.A$Inner    -> p.A          classes",
                                                   "   p.A          -> java.lang.Object  java.base",
                                                   "   p.Hidden     -> p.B          classes"]),
                             "sources": {"p.A": "src/p/A.java", "p.A$Inner": "src/p/A.java", "p.B": "src/p/B.java", "p.Hidden": "src/p/B.java"}})
        self.assertEqual(java_classes(output, {"src/p/A.java", "src/p/B.java"}), {("src/p/A.java", "src/p/B.java")})
        with self.assertRaises(ValueError):
            java_classes(json.dumps({"jdeps": "", "sources": {}}), set())


if __name__ == "__main__":
    unittest.main()
