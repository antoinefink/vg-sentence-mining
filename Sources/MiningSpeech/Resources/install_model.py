"""Download one pinned speech model. Called by the native in-app installer."""
from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import sys
import time

MODELS = {
    "parakeet-ultra": ("handy-computer/parakeet-ultra-gguf", "a1539be1b849ea7463b88343e5277b373d0c4ea9", "parakeet-ultra-Q8_0.gguf"),
    "whisper-large-v3": ("mlx-community/whisper-large-v3-mlx", "49e6aa286ad60c14352c404340ded53710378a11", None),
    "qwen3-asr-1.7b": ("Qwen/Qwen3-ASR-1.7B", "7278e1e70fe206f11671096ffdd38061171dd6e5", None),
    "qwen3-aligner": ("Qwen/Qwen3-ForcedAligner-0.6B", "c7cbfc2048c462b0d63a45797104fc9db3ad62b7", None),
}
PATTERNS = ("*.json", "*.safetensors", "*.npz", "*.txt", "*.tiktoken", "*.model")
NAMES = {"parakeet-ultra": "Parakeet Ultra", "whisper-large-v3": "Whisper Large V3",
         "qwen3-asr-1.7b": "Qwen3-ASR 1.7B", "qwen3-aligner": "the word alignment model"}


def emit(message, completed=None, total=None):
    print(json.dumps(dict(message=message, completed=completed, total=total)), flush=True)


def required_models(model):
    if model not in MODELS or model == "qwen3-aligner":
        raise ValueError("Choose a supported speech model.")
    return [model, "qwen3-aligner"] if model == "qwen3-asr-1.7b" else [model]


def publish(runtime, entries, model):
    path = runtime / "manifest.json"
    manifest = json.loads(path.read_text()) if path.exists() else {"protocol": 1, "models": {}}
    if manifest.get("protocol") != 1:
        raise ValueError("Unsupported speech installation format.")
    manifest["models"].update(entries)
    manifest.setdefault("environments", {})[model] = f"Environments/{model}/.venv/bin/python"
    temporary = runtime / "manifest.json.tmp"
    temporary.write_text(json.dumps(manifest, indent=2) + "\n")
    temporary.replace(path)


def download(destination, model):
    runtime = destination / "SpeechRuntime"
    os.environ.update(HF_HUB_DISABLE_IMPLICIT_TOKEN="1", HF_HUB_DISABLE_XET="1",
                      HF_HOME=str(runtime / "cache/huggingface"), HF_HUB_DOWNLOAD_TIMEOUT="60")
    from huggingface_hub import HfApi, hf_hub_download
    from tqdm.auto import tqdm
    entries = {}
    for name in required_models(model):
        repository, revision, filename = MODELS[name]
        info = HfApi(token=False).model_info(repository, revision=revision, files_metadata=True)
        if info.sha != revision:
            raise ValueError("The model revision could not be verified.")
        files = [s for s in info.siblings if (s.rfilename == filename if filename else
                 any(fnmatch.fnmatch(s.rfilename, p) for p in PATTERNS))]
        if not files:
            raise ValueError("The model download contains no files.")
        total = sum(f.size or 0 for f in files)
        completed = 0
        folder = destination / "Models" / name / revision
        for asset in files:
            emit(f"Downloading {NAMES[name]}…", completed, total)

            class Progress(tqdm):
                last_report = 0

                def update(self, n=1):
                    result = super().update(n)
                    now = time.monotonic()
                    if now - self.last_report > 0.2:
                        emit(f"Downloading {NAMES[name]}…", min(total, completed + self.n), total)
                        self.last_report = now
                    return result

            path = Path(hf_hub_download(repository, asset.rfilename, revision=revision,
                                       local_dir=folder, token=False, tqdm_class=Progress))
            if asset.size is not None and path.stat().st_size != asset.size:
                path.unlink()
                raise ValueError("A model file is incomplete. Retry the download.")
            if asset.lfs and asset.lfs.sha256:
                emit("Verifying the downloaded model…")
                with path.open("rb") as stream:
                    digest = hashlib.file_digest(stream, "sha256").hexdigest()
                if digest != asset.lfs.sha256:
                    path.unlink()
                    raise ValueError("A model file could not be verified. Retry the download.")
            completed += asset.size or 0
        entries[name] = {"path": str((folder / filename if filename else folder).relative_to(destination / "Models")),
                         "repository": repository, "revision": revision}
    # Relative interpreter links keep the entire speech folder movable.
    executable = runtime / "Environments" / model / ".venv/bin/python"
    if executable.is_symlink():
        target = executable.resolve()
        if target.is_relative_to(runtime):
            temporary_link = executable.with_name(".python-relocatable")
            temporary_link.unlink(missing_ok=True)
            temporary_link.symlink_to(os.path.relpath(target, executable.parent))
            temporary_link.replace(executable)
    emit("Checking the speech engine…")
    if model == "parakeet-ultra":
        import numpy
        import transcribe_cpp
    elif model == "whisper-large-v3":
        import mlx_whisper
    else:
        import mlx_qwen3_asr
    publish(runtime, entries, model)
    emit("Speech model installed.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", required=True, type=Path)
    parser.add_argument("--model", choices=[m for m in MODELS if m != "qwen3-aligner"], required=True)
    args = parser.parse_args()
    try:
        download(args.destination, args.model)
    except Exception as error:
        print(f"Installation failed: {error}", file=sys.stderr)
        raise SystemExit(1)
