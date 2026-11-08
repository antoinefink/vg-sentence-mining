"""CPU-only regression checks; no model packages, downloads, or GPU required."""
import base64
import importlib.util
import json
import math
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

WORKER = Path(__file__).resolve().parents[2] / "Sources/MiningSpeech/Resources/speech_worker.py"
spec = importlib.util.spec_from_file_location("speech_worker", WORKER)
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


def request(samples, **overrides):
    return {"id": "abdc-1234", "audio": base64.b64encode(struct.pack("<" + "f" * len(samples), *samples)).decode(),
            "language": "de", "glossary": [], **overrides}


class ModelLocationTests(unittest.TestCase):
    def test_runner_loads_selected_folder_with_a_legacy_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            runtime = Path(directory) / "runtime"
            runtime.mkdir()
            models = Path(directory) / "Chosen Models"
            selected = models / "whisper-large-v3" / "revision-1"
            selected.mkdir(parents=True)
            (runtime / "manifest.json").write_text(json.dumps({
                "protocol": 1, "models": {"whisper-large-v3": {
                    "path": "/old/disk/models/whisper-large-v3/revision-1", "revision": "revision-1"
                }}
            }))
            loaded = []
            module = types.SimpleNamespace(
                ModelHolder=types.SimpleNamespace(get_model=lambda path, dtype: loaded.append(path)),
                transcribe=lambda *args, **kwargs: None)
            mx = types.SimpleNamespace(float16="float16")
            with patch.dict(sys.modules, {"mlx": types.SimpleNamespace(core=mx), "mlx.core": mx}), \
                    patch.object(worker.importlib, "import_module", return_value=module):
                worker.Runner(runtime, "whisper-large-v3", models)
            self.assertEqual(loaded, [str(selected)])

    def test_moved_models_override_old_absolute_manifest_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            old = root / "original" / "whisper-large-v3" / "revision-1"
            old.mkdir(parents=True)
            selected = root / "Selected Models"
            moved = selected / "whisper-large-v3" / "revision-1"
            moved.mkdir(parents=True)
            metadata = {"path": str(old), "revision": "revision-1"}
            self.assertEqual(worker.model_path(selected, "whisper-large-v3", metadata), moved)
            moved.rmdir()
            with self.assertRaises(FileNotFoundError):
                worker.model_path(selected, "whisper-large-v3", metadata)

    def test_relative_manifest_and_native_file_are_relocatable(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            native = root / "parakeet-ultra" / "revision-2" / "model-q8.gguf"
            native.parent.mkdir(parents=True)
            native.touch()
            for stored in ["/old/models/parakeet-ultra/revision-2/model-q8.gguf",
                           "parakeet-ultra/revision-2/model-q8.gguf"]:
                self.assertEqual(worker.model_path(root, "parakeet-ultra", {
                    "path": stored, "revision": "revision-2"
                }), native)
            aligner = root / "qwen3-aligner" / "revision-3"
            aligner.mkdir(parents=True)
            self.assertEqual(worker.model_path(root, "qwen3-aligner", {
                "path": "qwen3-aligner/revision-3", "revision": "revision-3"
            }), aligner)

    def test_installer_writes_portable_model_paths(self):
        install_path = Path(__file__).with_name("install.py")
        install_spec = importlib.util.spec_from_file_location("speech_install", install_path)
        installer = importlib.util.module_from_spec(install_spec)
        install_spec.loader.exec_module(installer)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "benchmark"
            (source / "models").mkdir(parents=True)
            for name in installer.MODEL_IDS:
                origin = root / "downloaded" / name
                origin.mkdir(parents=True)
                weights = origin / "weights.bin"
                weights.write_bytes(b"fixture weights")
                (source / "models" / f"{name}.json").write_text(json.dumps({
                    "id": name, "status": "downloaded", "revision": "revision-1", "repository": "example/model",
                    "path": str(weights if name == "parakeet-ultra" else origin)
                }))
            selected = root / "Installed Models"
            entries = installer.install_models(source, selected)
            for name, metadata in entries.items():
                self.assertFalse(Path(metadata["path"]).is_absolute())
                self.assertTrue(worker.model_path(selected, name, metadata).exists())


class NormalizationTests(unittest.TestCase):
    def assert_playable(self, words, duration):
        for word in words:
            self.assertTrue(math.isfinite(word["start"]) and math.isfinite(word["end"]))
            self.assertTrue(0 <= word["start"] < word["end"] <= duration, word)
            self.assertLessEqual(word["end"] - word["start"], 3.000001)

    def test_qwen_restores_punctuation_case_and_split_tokens(self):
        text = "¡Busca a Vesemir! Weißgarten, d'Artagnan."
        raw = [{"text": "busca", "start": 0.3, "end": 0.8},
               {"text": "a", "start": 0.9, "end": 0.9},
               {"text": "Vesemir", "start": 0.9, "end": 1.5},
               {"text": "Weißgarten", "start": 1.7, "end": 2.2},
               {"text": "d", "start": 2.3, "end": 2.4},
               {"text": "Artagnan", "start": 2.4, "end": 2.9}]
        words = worker.normalized_words(text, raw, 3)
        self.assertEqual([w["text"] for w in words], text.split())
        self.assertEqual(words[-1]["start"], 2.3)
        self.assertEqual(words[-1]["end"], 2.9)
        self.assert_playable(words, 3)

    def test_observed_spanish_zero_duration_keeps_word(self):
        text = "allí a Besemir."
        words = worker.normalized_words(text, [{"text": "allí", "start": 3.36, "end": 3.52},
                                               {"text": "a", "start": 3.52, "end": 3.52},
                                               {"text": "Besemir", "start": 3.52, "end": 4.08}], 4.27)
        self.assertEqual([w["text"] for w in words], text.split())
        self.assertEqual(words[1]["start"], 3.52)
        self.assert_playable(words, 4.27)

    def test_observed_pause_span_is_bounded_without_changing_onset(self):
        words = worker.normalized_words("Bescheid. Ah! Ich", [
            {"text": "Bescheid", "start": 45.3, "end": 45.78},
            {"text": "Ah", "start": 48.81, "end": 56.57},
            {"text": "Ich", "start": 76.734, "end": 76.894}], 90)
        self.assertEqual(words[1]["text"], "Ah!")
        self.assertEqual(words[1]["start"], 48.81)
        self.assertLessEqual(words[1]["end"], 50.81)
        self.assert_playable(words, 90)

    def test_ultra_valid_offsets_are_not_rebased(self):
        raw = [{"text": "Die", "start": 2.22, "end": 2.46},
               {"text": "temerische", "start": 2.46, "end": 3.14},
               {"text": "Armee.", "start": 3.14, "end": 3.5}]
        self.assertEqual(worker.normalized_words("Die temerische Armee.", raw, 8), raw)

    def test_invalid_missing_and_boundary_intervals_keep_all_text(self):
        text = "Ich bin ein kleiner Baum."
        raw = [{"text": "Ich", "start": float("nan"), "end": float("inf")},
               {"text": "bin", "start": -1, "end": 0},
               {"text": "ein", "start": 49.2, "end": 49.2},
               {"text": "kleiner", "start": 49.2, "end": 49.2},
               {"text": "Baum", "start": 55, "end": 60}]
        words = worker.normalized_words(text, raw, 49.2)
        self.assertEqual([w["text"] for w in words], text.split())
        self.assert_playable(words, 49.2)
        self.assert_playable(worker.normalized_words(text, [], 0.01), 0.01)


class CodecTests(unittest.TestCase):
    def test_little_endian_roundtrip(self):
        audio, language, glossary = worker.decode_request(request([0, -0.5, 1], language="es", glossary=["  Kaer   Morhen  "]))
        self.assertEqual(list(audio), [0, -0.5, 1])
        self.assertEqual(language, "es")
        self.assertEqual(glossary, ["Kaer Morhen"])

    def test_invalid_audio_language_and_glossary_are_rejected(self):
        for case in [request([float("nan")]), request([float("inf")]), request([], language="en"),
                     request([], glossary=[1]), request([], audio="@!"),
                     request([], audio=base64.b64encode(b"abc").decode()),
                     request([], audio="A" * (worker.MAX_AUDIO_BASE64 + 4))]:
            with self.subTest(case=str(case)[:80]), self.assertRaises(worker.RequestError):
                worker.decode_request(case)

    def test_32_seconds_limit(self):
        encoded = base64.b64encode(b"\0" * worker.MAX_SAMPLES * 4).decode()
        self.assertEqual(len(worker.decode_request(request([], audio=encoded))[0]), worker.MAX_SAMPLES)
        with self.assertRaises(worker.RequestError):
            worker.decode_request(request([], audio=encoded + "AAAA"))

    def test_digital_silence(self):
        self.assertTrue(worker.is_silent([]))
        self.assertTrue(worker.is_silent([0, -0.000001, 0.00001]))
        self.assertFalse(worker.is_silent([0, 0.000011]))

    def test_glossary_is_short(self):
        _, _, glossary = worker.decode_request(request([], glossary=["X" * 100] * 100))
        self.assertLessEqual(len(", ".join(glossary)), 512)
        self.assertTrue(all(len(term) <= 80 for term in glossary))


class ProtocolTests(unittest.TestCase):
    def test_native_stdout_is_separate_and_eof_closes_runner(self):
        # Replace only the model boundary; exercise the real entry point,
        # fd redirection, request codec, silent shortcut and EOF cleanup.
        script = '''
import importlib.util, os, sys, types
spec = importlib.util.spec_from_file_location("speech_worker", sys.argv[1])
w = importlib.util.module_from_spec(spec); spec.loader.exec_module(w)
sys.modules["numpy"] = types.SimpleNamespace(asarray=lambda a, dtype: a, float32=float)
class Runner:
    glossary_supported = True
    def __init__(self, runtime, model, models):
        print("python loader noise", flush=True)
        os.write(1, b"native loader noise\\n")
    def run(self, audio, language, glossary):
        os.write(1, b"native inference noise\\n")
        if glossary == ["fail"]: raise ValueError("private model detail")
        return {"text":"Hallo!", "words":[{"text":"Hallo!", "start":0.0, "end":0.02}]}
    def close(self): os.write(2, b"closed\\n")
w.Runner = Runner
sys.argv = [sys.argv[1], "--runtime", sys.argv[2], "--models", sys.argv[2], "--model", "whisper-large-v3"]
raise SystemExit(w.main())
'''
        with tempfile.TemporaryDirectory() as directory:
            payloads = [request([0]), request([0.1]), request([0.1], glossary=["fail"])]
            result = subprocess.run([sys.executable, "-c", script, str(WORKER), directory],
                                    input="\n".join(json.dumps(value) for value in payloads) + "\n", text=True,
                                    capture_output=True, check=True)
        lines = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(len(lines), 4)
        self.assertEqual(lines[0], {"kind": "ready", "protocol": 1, "model": "whisper-large-v3", "glossarySupported": True})
        self.assertEqual(lines[1]["words"], [])
        self.assertEqual(lines[2]["text"], "Hallo!")
        self.assertNotIn("private", lines[3]["error"])
        self.assertEqual(result.stderr.count("native inference noise"), 2)
        self.assertIn("native loader noise", result.stderr)
        self.assertIn("python loader noise", result.stderr)
        self.assertIn("closed", result.stderr)


if __name__ == "__main__":
    unittest.main()
