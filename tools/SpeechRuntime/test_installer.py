"""Offline installer regression tests. Run in Docker; no model packages needed."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import types
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[2] / "Sources/MiningSpeech/Resources/install_model.py"
spec = importlib.util.spec_from_file_location("install_model", SCRIPT)
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class InstallerTests(unittest.TestCase):
    def test_only_the_requested_model_is_downloaded_and_published(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "SpeechRuntime").mkdir()
            calls = []
            content = b"verified model bytes"
            asset = types.SimpleNamespace(rfilename="model.safetensors", size=len(content),
                                          lfs=types.SimpleNamespace(sha256=hashlib.sha256(content).hexdigest()))

            def info(repo, revision, files_metadata):
                calls.append(repo)
                return types.SimpleNamespace(sha=revision, siblings=[asset])

            def fetch(repo, name, revision, local_dir, **kwargs):
                local_dir.mkdir(parents=True, exist_ok=True)
                target = local_dir / name
                target.write_bytes(content)
                return str(target)

            hf = types.SimpleNamespace(HfApi=lambda **kwargs: types.SimpleNamespace(model_info=info), hf_hub_download=fetch)
            with patch.dict("sys.modules", {"huggingface_hub": hf, "tqdm": types.ModuleType("tqdm"),
                                           "tqdm.auto": types.SimpleNamespace(tqdm=object), "mlx_whisper": types.ModuleType("mlx_whisper")}), \
                    patch.object(installer, "emit"):
                installer.download(root, "whisper-large-v3")
            self.assertEqual(calls, [installer.MODELS["whisper-large-v3"][0]])
            manifest = json.loads((root / "SpeechRuntime/manifest.json").read_text())
            self.assertEqual(set(manifest["models"]), {"whisper-large-v3"})

    def test_failed_download_preserves_existing_models_and_retry_succeeds(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            runtime = root / "SpeechRuntime"
            runtime.mkdir()
            existing = {"protocol": 1, "models": {"parakeet-ultra": {"path": "existing"}}, "native": {"library": "keep"}}
            path = runtime / "manifest.json"
            path.write_text(json.dumps(existing))
            asset = types.SimpleNamespace(rfilename="model.safetensors", size=4,
                                          lfs=types.SimpleNamespace(sha256="0" * 64))

            def fetch(repo, name, revision, local_dir, **kwargs):
                local_dir.mkdir(parents=True, exist_ok=True)
                target = local_dir / name
                target.write_bytes(b"bad!")
                return str(target)

            api = types.SimpleNamespace(model_info=lambda repo, revision, **kwargs: types.SimpleNamespace(sha=revision, siblings=[asset]))
            hf = types.SimpleNamespace(HfApi=lambda **kwargs: api, hf_hub_download=fetch)
            with patch.dict("sys.modules", {"huggingface_hub": hf, "tqdm": types.ModuleType("tqdm"),
                                           "tqdm.auto": types.SimpleNamespace(tqdm=object)}), patch.object(installer, "emit"):
                with self.assertRaisesRegex(ValueError, "verified"):
                    installer.download(root, "whisper-large-v3")
            self.assertEqual(json.loads(path.read_text()), existing)
            installer.publish(runtime, {"whisper-large-v3": {"path": "new"}}, "whisper-large-v3")
            self.assertEqual(set(json.loads(path.read_text())["models"]), {"parakeet-ultra", "whisper-large-v3"})
            self.assertEqual(json.loads(path.read_text())["native"], existing["native"])

    def test_qwen_requires_its_aligner_and_invalid_models_are_rejected(self):
        self.assertEqual(installer.required_models("qwen3-asr-1.7b"), ["qwen3-asr-1.7b", "qwen3-aligner"])
        with self.assertRaises(ValueError):
            installer.required_models("qwen3-aligner")
        with self.assertRaises(ValueError):
            installer.required_models("../other")


if __name__ == "__main__":
    unittest.main()
