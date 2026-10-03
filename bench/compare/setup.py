"""Pinned, scratch-only installation; also usable independently of run.py."""
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tarfile

HERE = Path(__file__).resolve().parent
PINS = json.loads((HERE / "pins.json").read_text())


def environment(scratch):
    env = os.environ.copy()
    env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1')
    for key in ("PYTHONPATH", "PYTHONHOME", "NODE_OPTIONS", "NODE_PATH", "GOFLAGS", "GOOS", "GOARCH", "RUSTC_WRAPPER", "RUSTC_WORKSPACE_WRAPPER", "RUSTFLAGS", "CARGO_ENCODED_RUSTFLAGS", "FORCE_COLOR"):
        env.pop(key, None)
    for key, sub in {"CARGO_HOME": "cargo-home", "CARGO_TARGET_DIR": "cargo-target", "GOPATH": "gopath", "GOCACHE": "go-cache", "GOMODCACHE": "gopath/pkg/mod", "npm_config_cache": "npm-cache", "XDG_CACHE_HOME": "cache", "UV_CACHE_DIR": "uv-cache", "PIP_CACHE_DIR": "pip-cache", "ZIG_GLOBAL_CACHE_DIR": "zig-cache"}.items():
        env[key] = str(scratch / sub)
    env.update(GOENV="off", GOTOOLCHAIN="local", GOWORK="off", NO_COLOR="1", CARGO_BUILD_JOBS="2", PIP_CONFIG_FILE=os.devnull,
               PYTHONDONTWRITEBYTECODE="1", npm_config_userconfig=str(scratch / "npm-user.conf"), npm_config_globalconfig=str(scratch / "npm-global.conf"))
    scratch.mkdir(parents=True, exist_ok=True)
    for name in ("npm-user.conf", "npm-global.conf"):
        if not (scratch / name).exists(): (scratch / name).write_text("")
    (scratch / "tmp").mkdir(exist_ok=True)
    env.update(TMPDIR=str(scratch / "tmp"), TMP=str(scratch / "tmp"), TEMP=str(scratch / "tmp"))
    # Use installed toolchain binaries directly, avoiding rustup overrides in the corpus.
    cargo = shutil.which("cargo")
    if shutil.which("rustup"):
        cargo = subprocess.check_output(["rustup", "which", "cargo"], text=True).strip()
    bins = [str(scratch / "npm/node_modules/.bin"), str(scratch / "venv/bin"), str(scratch / "cargo/bin"), str(Path(cargo).parent)]
    if not shutil.which("node") and Path("/opt/homebrew/opt/node@22/bin").exists():
        bins.append("/opt/homebrew/opt/node@22/bin")
    env["PATH"] = os.pathsep.join(bins + [env["PATH"]])
    return env


def jdk_home(scratch):
    """The pinned JDK unpacked in scratch: `Contents/Home` on macOS."""
    root = scratch / "jdk" / ("jdk-" + PINS["jdk"]["version"])
    return root / "Contents/Home" if (root / "Contents/Home").exists() else root


def checkout(repo, url, commit, env):
    if not (repo / ".git").exists():
        run(["git", "init", str(repo)], env)
        run(["git", "-C", str(repo), "remote", "add", "origin", url], env)
        run(["git", "-C", str(repo), "fetch", "--depth=1", "origin", commit], env)
        run(["git", "-C", str(repo), "checkout", "--detach", commit], env)
    head = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], env=env, text=True).strip()
    if head != commit:
        raise RuntimeError(f"wrong corpus commit in {repo}: {head}")
    if subprocess.check_output(["git", "-C", str(repo), "status", "--porcelain", "--untracked-files=no"], env=env):
        raise RuntimeError(f"modified corpus: {repo}")


def run(command, env, cwd=None):
    print("+", " ".join(map(str, command)), flush=True)
    subprocess.run(command, env=env, cwd=cwd, check=True)


def prepare(scratch, languages):
    scratch.mkdir(parents=True, exist_ok=True)
    env = environment(scratch)
    (scratch / "repos").mkdir(exist_ok=True)
    for language in languages:
        pin = PINS["repositories"][language]
        repo = scratch / "repos" / language
        checkout(repo, pin["url"], pin["commit"], env)
        # Pinned sources a corpus's own tooling would fetch (Nim's `koch deps`).
        for dependency in pin.get("dependencies", []):
            checkout(repo / dependency["path"], dependency["url"], dependency["commit"], env)
    if "java" in languages and not (jdk_home(scratch) / "bin/jdeps").exists():
        key = f"{sys.platform}-{platform.machine().lower().replace('aarch64', 'arm64')}"
        archive = PINS["jdk"]["archives"].get(key)
        if archive is None:
            raise RuntimeError(f"no pinned JDK for {key}")
        download = scratch / "downloads" / Path(archive["url"]).name.replace("%2B", "+")
        download.parent.mkdir(exist_ok=True)
        if not download.exists():
            run(["curl", "-fsSL", "-o", str(download), archive["url"]], env)
        digest = hashlib.sha256(download.read_bytes()).hexdigest()
        if digest != archive["sha256"]:
            raise RuntimeError(f"JDK archive digest {digest} differs from pin")
        with tarfile.open(download) as tar:
            tar.extractall(scratch / "jdk", filter="tar")
    if "typescript" in languages:
        npm = scratch / "npm"
        npm.mkdir(exist_ok=True)
        package = {"private": True, "dependencies": PINS["npm"]}
        (npm / "package.json").write_text(json.dumps(package, indent=2) + "\n")
        lock = HERE / "npm-lock.json"
        if lock.exists():
            shutil.copyfile(lock, npm / "package-lock.json")
            run(["npm", "ci", "--prefix", str(npm), "--no-audit", "--no-fund"], env)
        else:
            run(["npm", "install", "--prefix", str(npm), "--no-audit", "--no-fund"], env)
    if "python" in languages:
        if not (scratch / "venv/bin/pip").exists():
            run([sys.executable, "-m", "venv", str(scratch / "venv")], env)
        requirements = HERE / "requirements.txt"
        args = ["-r", str(requirements)] if requirements.exists() else [f"{k}=={v}" for k, v in PINS["python"].items()]
        run([str(scratch / "venv/bin/python"), "-m", "pip", "install", *args], env)
    if "rust" in languages and not (scratch / "cargo/bin/cargo-modules").exists():
        run(["cargo", "install", "--locked", "--root", str(scratch / "cargo"), "--version", PINS["cargo"]["cargo-modules"], "cargo-modules"], env)
    return env


def verify_tools(scratch, languages, env):
    versions = {}
    if "typescript" in languages:
        for name, expected in PINS["npm"].items():
            actual = json.loads((scratch / "npm/node_modules" / name / "package.json").read_text())["version"]
            if actual != expected:
                raise RuntimeError(f"{name}: expected {expected}, found {actual}")
            versions[name] = actual
    if "python" in languages:
        code = "import importlib.metadata as m,json; print(json.dumps({n:m.version(n) for n in ['pydeps','grimp','import-linter']}))"
        actual = json.loads(subprocess.check_output([str(scratch / "venv/bin/python"), "-c", code], env=env, text=True))
        if actual != PINS["python"]:
            raise RuntimeError(f"Python rivals differ from pins: {actual}")
        versions.update(actual)
    if "nim" in languages:
        actual = subprocess.check_output(["nim", "--version"], env=env, text=True).split()[3]
        if actual != PINS["toolchains"]["nim"]:
            raise RuntimeError(f"nim {actual} differs from pin {PINS['toolchains']['nim']}")
        versions["nim"] = actual
    if "java" in languages:
        release = (jdk_home(scratch) / "release").read_text()
        if f'JAVA_RUNTIME_VERSION="{PINS["jdk"]["version"]}' not in release:
            raise RuntimeError("JDK differs from pin")
        versions["jdk"] = PINS["jdk"]["version"]
    if "rust" in languages:
        installed = json.loads((scratch / "cargo/.crates2.json").read_text())["installs"]
        if not any(key.startswith("cargo-modules " + PINS["cargo"]["cargo-modules"] + " ") for key in installed):
            raise RuntimeError("cargo-modules differs from pin")
        versions.update(PINS["cargo"])
    return versions


if __name__ == "__main__":
    prepare(Path(sys.argv[1]).resolve(), sys.argv[2:] or list(PINS["repositories"]))
