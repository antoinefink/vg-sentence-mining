"""Install the retained, pinned local ASR stack without network downloads.

Run with native Python on macOS. The app never invokes this installer.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import errno
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

MODEL_IDS = ("parakeet-ultra", "whisper-large-v3", "qwen3-asr-1.7b", "qwen3-aligner")
NATIVE_REVISION = "5700f127e38dd53c4735ea23ef743b4b538eacd4"


def run(arguments: list[str], **kwargs) -> str:
    return subprocess.run(arguments, check=True, text=True, stdout=subprocess.PIPE, **kwargs).stdout


def copy_asset(source: str, destination: str):
    """Dereference HF snapshot symlinks; hardlinks survive source deletion."""
    source_path, destination_path = Path(source).resolve(), Path(destination)
    if destination_path.exists():
        if source_path.stat().st_size != destination_path.stat().st_size:
            raise ValueError(f"Existing asset differs in size: {destination_path}")
        return
    destination_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        os.link(source_path, destination_path)
    except OSError as error:
        if error.errno not in (errno.EXDEV, errno.ENOTSUP, errno.EPERM):
            raise
        shutil.copy2(source_path, destination_path)


def install_models(source: Path, destination: Path) -> dict:
    models = {}
    for model in MODEL_IDS:
        metadata = json.loads((source / "models" / f"{model}.json").read_text())
        if metadata["status"] != "downloaded" or metadata["id"] != model:
            raise ValueError(f"Missing retained model: {model}")
        origin = Path(metadata["path"])
        target = destination / model / metadata["revision"]
        if origin.is_file():
            target = target / origin.name
            copy_asset(str(origin), str(target))
        elif origin.is_dir():
            shutil.copytree(origin, target, symlinks=False, dirs_exist_ok=True, copy_function=copy_asset,
                            ignore=shutil.ignore_patterns(".cache"))
        else:
            raise FileNotFoundError(origin)
        models[model] = {"path": str(target.relative_to(destination)), "repository": metadata["repository"],
                         "revision": metadata["revision"]}
    return models


def install_native(source: Path, runtime: Path) -> dict:
    checkout = source / "runtimes" / "transcribe.cpp"
    revision = run(["git", "-C", str(checkout), "rev-parse", "HEAD"]).strip()
    if revision != NATIVE_REVISION:
        raise ValueError("The retained native runtime revision differs from the benchmark.")
    binding = runtime / "python" / "transcribe_cpp"
    shutil.copytree(checkout / "bindings" / "python" / "src" / "transcribe_cpp", binding,
                    dirs_exist_ok=True, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    lib = runtime / "lib"
    lib.mkdir(parents=True, exist_ok=True)
    originals = list((source / "runtimes" / "transcribe-build").rglob("*.dylib"))
    names = {item.name for item in originals}
    for item in originals:
        target = lib / item.name
        if target.exists() or target.is_symlink():
            target.unlink()
        # Never edit a hardlink to a retained benchmark binary.
        if item.is_symlink():
            target.symlink_to(item.resolve().name)
        else:
            shutil.copy2(item, target)
    for target in sorted(lib.glob("*.dylib")):
        if target.is_symlink():
            continue
        dependencies = run(["otool", "-L", str(target)]).splitlines()[1:]
        for entry in dependencies:
            dependency = entry.strip().split(" (", 1)[0]
            name = Path(dependency).name
            if name in names:
                run(["install_name_tool", "-change", dependency, f"@loader_path/{name}", str(target)])
            elif not dependency.startswith(("/usr/lib/", "/System/Library/")):
                raise ValueError(f"Unbundled native dependency: {dependency}")
        run(["install_name_tool", "-id", f"@loader_path/{target.name}", str(target)])
        commands = run(["otool", "-l", str(target)]).splitlines()
        for index, line in enumerate(commands):
            if line.strip() == "cmd LC_RPATH":
                path = commands[index + 2].strip().removeprefix("path ").rsplit(" (offset", 1)[0]
                run(["install_name_tool", "-delete_rpath", path, str(target)])
        run(["install_name_tool", "-add_rpath", "@loader_path", str(target)])
        run(["codesign", "--force", "--sign", "-", str(target)])
        run(["codesign", "--verify", "--strict", str(target)])
    library = lib / "libtranscribe.0.4.1.dylib"
    if not library.is_file():
        raise FileNotFoundError(library)
    return {"pythonPath": "python", "library": str(library.relative_to(runtime)), "revision": revision}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True,
                        help="Speech folder that will contain Models and SpeechRuntime")
    args = parser.parse_args()
    if sys.platform != "darwin":
        raise RuntimeError("Install the local Metal speech runtime on macOS.")
    source = args.source.resolve()
    destination = args.destination.expanduser().resolve()
    runtime, models_path = destination / "SpeechRuntime", destination / "Models"
    if runtime == source or source in runtime.parents or models_path == source or source in models_path.parents or runtime == models_path:
        raise ValueError("The runtime and model directories must be independent of the retained benchmark.")
    uv = shutil.which("uv")
    if uv is None:
        raise FileNotFoundError("Install uv before preparing the speech runtime.")
    runtime.mkdir(parents=True, exist_ok=True)
    config = dict(line.split(" = ", 1) for line in (source / ".venv" / "pyvenv.cfg").read_text().splitlines() if " = " in line)
    version = config["version_info"]
    if version != "3.12.11":
        raise ValueError("The retained Python version differs from the pinned runtime.")
    python = Path(config["home"]) / "python3.12"
    if not python.exists():
        raise FileNotFoundError(python)
    requirements = Path(__file__).with_name("requirements.txt")
    if requirements.read_text().splitlines() != (source / "requirements-resolved.txt").read_text().splitlines():
        raise ValueError("The retained package versions differ from the pinned requirements.")
    environment = {**os.environ, "UV_OFFLINE": "1", "UV_PYTHON_DOWNLOADS": "never",
                   "UV_CACHE_DIR": str(source.parent / "cache" / "uv")}
    venv = runtime / ".venv"
    if not (venv / "bin" / "python").exists():
        run([uv, "venv", "--python", str(python), str(venv)], env=environment)
    installed_python = venv / "bin" / "python"
    if run([str(installed_python), "-c", "import platform; print(platform.python_version())"]).strip() != version:
        raise ValueError("The speech runtime uses the wrong Python version.")
    run([uv, "pip", "sync", "--offline", "--python", str(installed_python), str(requirements)], env=environment)
    run([uv, "pip", "check", "--python", str(installed_python)], env=environment)
    shutil.copy2(requirements, runtime / "requirements.txt")
    manifest = {"protocol": 1, "python": ".venv/bin/python", "pythonVersion": version,
                "installedAt": datetime.now(timezone.utc).isoformat(),
                "models": install_models(source, models_path), "native": install_native(source, runtime)}
    temporary = runtime / "manifest.json.tmp"
    temporary.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    temporary.replace(runtime / "manifest.json")
    print(json.dumps({"runtime": str(runtime), "manifest": str(runtime / "manifest.json"),
                      "models": list(manifest["models"])}, ensure_ascii=False))


if __name__ == "__main__":
    main()
