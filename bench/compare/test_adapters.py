"""Small format checks: catch direction errors, external leakage and item collapse."""
import json
from pathlib import Path
import tempfile
import unittest

from run import json_stream, normalise, rust_dot


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


if __name__ == "__main__":
    unittest.main()
