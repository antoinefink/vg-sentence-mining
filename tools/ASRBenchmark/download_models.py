"""Download pinned public checkpoints into the chosen benchmark directory."""
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import sys

ROOT = Path(sys.argv[1]).resolve()
os.environ["HF_HOME"] = str(ROOT / "cache" / "huggingface")
os.environ["HF_XET_CACHE"] = str(ROOT / "cache" / "xet")
os.environ["HF_HUB_DISABLE_IMPLICIT_TOKEN"] = "1"
os.environ["HF_HUB_DISABLE_XET"] = "1"
os.environ["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"

from huggingface_hub import HfApi, hf_hub_download, snapshot_download

MODELS = {
    "qwen3-asr-1.7b": ("Qwen/Qwen3-ASR-1.7B", "7278e1e70fe206f11671096ffdd38061171dd6e5", None),
    "qwen3-aligner": ("Qwen/Qwen3-ForcedAligner-0.6B", "c7cbfc2048c462b0d63a45797104fc9db3ad62b7", None),
    "whisper-large-v3": ("mlx-community/whisper-large-v3-mlx", "49e6aa286ad60c14352c404340ded53710378a11", None),
    "whisper-turbo-mlx": ("mlx-community/whisper-large-v3-turbo", None, None),
    "parakeet-ultra": ("handy-computer/parakeet-ultra-gguf", None, "parakeet-ultra-Q8_0.gguf"),
}


def download(item):
    name, (repo, revision, filename) = item
    destination = ROOT / "models" / f"{name}.json"
    if destination.exists():
        retained = json.loads(destination.read_text())
        if retained.get("status") == "downloaded" and Path(retained["path"]).exists():
            print(json.dumps(retained), flush=True)
            return retained
        revision = retained.get("revision") or revision
    try:
        info = HfApi(token=False).model_info(repo, revision=revision)
        revision = info.sha
        if filename:
            path = hf_hub_download(repo, filename, revision=revision, token=False)
        else:
            path = snapshot_download(repo, revision=revision, token=False,
                                     allow_patterns=["*.json", "*.safetensors", "*.npz", "*.txt", "*.tiktoken", "*.model"])
        result = {"id": name, "repository": repo, "revision": revision, "path": path, "status": "downloaded"}
    except Exception as error:
        result = {"id": name, "repository": repo, "revision": revision, "status": "failed", "error": str(error)}
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    assert json.loads(destination.read_text())["status"] == result["status"]
    print(json.dumps(result), flush=True)
    return result


if __name__ == "__main__":
    ROOT.mkdir(parents=True, exist_ok=True)
    with ThreadPoolExecutor(max_workers=3) as pool:
        results = list(pool.map(download, MODELS.items()))
    (ROOT / "models.json").write_text(json.dumps(results, indent=2) + "\n")
