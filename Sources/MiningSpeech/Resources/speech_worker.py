"""Offline, single-model speech worker. Stdout is reserved for the JSON protocol."""
from __future__ import annotations

import argparse
import array
import base64
import binascii
from difflib import SequenceMatcher
import importlib
import json
import math
import os
from pathlib import Path
import re
import sys
import traceback
import unicodedata

MODELS = ("parakeet-ultra", "whisper-large-v3", "qwen3-asr-1.7b")
LANGUAGES = {"cs": "Czech", "da": "Danish", "nl": "Dutch", "en": "English", "fi": "Finnish",
             "fr": "French", "de": "German", "el": "Greek", "hu": "Hungarian", "id": "Indonesian",
             "it": "Italian", "pl": "Polish", "pt": "Portuguese", "ro": "Romanian", "ru": "Russian",
             "es": "Spanish", "sv": "Swedish", "tr": "Turkish", "uk": "Ukrainian", "vi": "Vietnamese"}
MODEL_LANGUAGES = {
    "parakeet-ultra": set(LANGUAGES) - {"id", "tr", "vi"},
    "whisper-large-v3": set(LANGUAGES),
    # The forced aligner supports fewer languages than the recognizer.
    "qwen3-asr-1.7b": {"en", "fr", "de", "it", "pt", "ru", "es"},
}
SAMPLE_RATE = 16000
MAX_SAMPLES = SAMPLE_RATE * 32
MAX_AUDIO_BASE64 = ((MAX_SAMPLES * 4 + 2) // 3) * 4


class RequestError(ValueError):
    pass


def lexical(text: str) -> str:
    return "".join(c for c in unicodedata.normalize("NFKC", text).casefold() if c.isalnum())


def finite(value):
    try:
        number = float(value)
        return number if math.isfinite(number) else None
    except (ValueError, TypeError, OverflowError):
        return None


def normalized_words(text: str, words: list[dict], duration: float) -> list[dict]:
    """Project transcript spelling onto alignment, retaining words with broken times.

    The Qwen aligner removes punctuation and sometimes splits a transcript token.
    Match normalized characters so apostrophes, compounds and sentence endings
    keep the recognizer's spelling. Repaired times are approximate, in the same
    audio window; a malformed alignment must not erase recognized dialogue.
    """
    tokens = re.findall(r"\S+", text)
    if not tokens or duration <= 0:
        return []
    target, owners = "", []
    for i, word in enumerate(words):
        chars = lexical(str(word.get("text", "")))
        target += chars
        owners.extend([i] * len(chars))
    source, spans = "", []
    for token in tokens:
        start = len(source)
        source += lexical(token)
        spans.append((start, len(source)))
    mapped = {}
    for block in SequenceMatcher(None, source, target, autojunk=False).get_matching_blocks():
        for offset in range(block.size):
            mapped[block.a + offset] = owners[block.b + offset]

    times = []
    for start, end in spans:
        indices = {mapped[i] for i in range(start, end) if i in mapped}
        starts = [finite(words[i].get("start")) for i in sorted(indices)]
        ends = [finite(words[i].get("end")) for i in sorted(indices)]
        starts = [v for v in starts if v is not None]
        ends = [v for v in ends if v is not None]
        times.append((min(starts) if starts else None, max(ends) if ends else None))

    output = []
    minimum = min(0.02, duration)
    for i, (token, (start, end)) in enumerate(zip(tokens, times)):
        if start is None:
            next_start = next((a for a, _ in times[i + 1:] if a is not None), duration)
            start = output[-1]["end"] if output else max(0.0, next_start - minimum)
        start = min(max(0.0, start), max(0.0, duration - minimum))
        if end is None or end <= start:
            end = start + minimum
        # Observed aligner words span multi-second pauses. Keep the onset and
        # a generous speech interval instead of exporting the whole pause.
        maximum = min(3.0, max(2.0, 0.08 * len(lexical(token))))
        end = min(duration, max(start + minimum, min(end, start + maximum)))
        output.append({"text": token, "start": start, "end": end})
    return output


def decode_request(request: dict):
    if not isinstance(request, dict) or not isinstance(request.get("id"), str):
        raise RequestError("The request needs an id.")
    if not isinstance(request.get("language"), str) or request["language"] not in LANGUAGES:
        raise RequestError("Choose a supported capture language.")
    encoded = request.get("audio")
    if not isinstance(encoded, str) or len(encoded) > MAX_AUDIO_BASE64:
        raise RequestError("Audio must contain at most 32 seconds of mono 16 kHz float32 samples.")
    try:
        data = base64.b64decode(encoded, validate=True)
    except (ValueError, binascii.Error):
        raise RequestError("Audio encoding is invalid.") from None
    if len(data) % 4 or len(data) > MAX_SAMPLES * 4:
        raise RequestError("Audio must contain at most 32 seconds of mono 16 kHz float32 samples.")
    audio = array.array("f")
    audio.frombytes(data)
    if sys.byteorder != "little":
        audio.byteswap()
    if not all(math.isfinite(sample) for sample in audio):
        raise RequestError("Audio contains invalid samples.")
    glossary = request.get("glossary", [])
    if not isinstance(glossary, list) or not all(isinstance(term, str) for term in glossary):
        raise RequestError("The glossary must contain text entries.")
    # Context stays short: long prompts can dominate recognition or hallucinate
    # the glossary, as seen in the retained silent benchmark cases.
    short, length = [], 0
    for term in glossary[:32]:
        term = " ".join(term.split())[:80]
        if term and length + len(term) <= 512:
            short.append(term)
            length += len(term) + 2
    return audio, request["language"], short


def is_silent(audio) -> bool:
    return not any(abs(sample) > 1e-5 for sample in audio)


def model_path(models: Path, name: str, metadata: dict) -> Path:
    relative = Path(metadata["path"])
    if relative.is_absolute():
        # Older installed manifests recorded absolute paths. Rebase their
        # installed layout onto the folder explicitly selected by the user.
        relative = Path(name) / metadata["revision"]
        if name == "parakeet-ultra":
            relative /= Path(metadata["path"]).name
    if relative.is_absolute() or ".." in relative.parts:
        raise ValueError("The model manifest path must stay within the models folder.")
    selected = models / relative
    if not selected.exists():
        raise FileNotFoundError(f"The installed {name} model is missing from the selected models folder.")
    return selected


class Runner:
    def __init__(self, runtime: Path, model: str, models: Path):
        manifest = json.loads((runtime / "manifest.json").read_text())
        if manifest["protocol"] != 1:
            raise ValueError("Unsupported speech runtime protocol.")
        self.model = model
        self.glossary_supported = model != "parakeet-ultra"
        path = str(model_path(models, model, manifest["models"][model]))
        self.path = path
        if model == "parakeet-ultra":
            if model not in manifest.get("environments", {}):
                sys.path.insert(0, str(runtime / manifest["native"]["pythonPath"]))
                os.environ["TRANSCRIBE_LIBRARY"] = str(runtime / manifest["native"]["library"])
            import transcribe_cpp
            self.native = transcribe_cpp.Model(path, backend="metal")
            self.session = self.native.session()
        elif model == "whisper-large-v3":
            import mlx.core as mx
            module = importlib.import_module("mlx_whisper.transcribe")
            module.ModelHolder.get_model(path, mx.float16)
            self.transcribe = module.transcribe
        else:
            import mlx.core as mx
            from mlx_qwen3_asr import ForcedAligner, Session
            self.session = Session(model=path, dtype=mx.float16)
            aligner_path = str(model_path(models, "qwen3-aligner", manifest["models"]["qwen3-aligner"]))
            if not Path(aligner_path).is_dir():
                raise FileNotFoundError("The installed word alignment model is missing.")
            self.aligner = ForcedAligner(model_path=aligner_path, dtype=mx.float16, backend="mlx")
            self.aligner._ensure_loaded()

    def run(self, audio, language: str, glossary: list[str]) -> dict:
        if language not in MODEL_LANGUAGES[self.model]:
            raise RequestError("This model does not support word timings for the selected language. Choose another transcription model.")
        if self.model == "whisper-large-v3":
            raw = self.transcribe(audio, path_or_hf_repo=self.path, language=language,
                                  task="transcribe", fp16=True, word_timestamps=True,
                                  initial_prompt=", ".join(glossary) or None,
                                  condition_on_previous_text=False, temperature=0.0, verbose=None)
            words = [{"text": word["word"], "start": word["start"], "end": word["end"]}
                     for segment in raw["segments"] for word in segment.get("words", [])]
            text = raw["text"]
        elif self.model == "qwen3-asr-1.7b":
            result = self.session.transcribe((audio, SAMPLE_RATE),
                                             language=LANGUAGES[language],
                                             context=", ".join(glossary), return_timestamps=True,
                                             forced_aligner=self.aligner, return_chunks=True, max_new_tokens=2048)
            text, words = result.text, result.segments or []
        else:
            result = self.session.run(audio, language=language, timestamps="word")
            text = result.text
            words = [{"text": word.text, "start": word.t0_ms / 1000, "end": word.t1_ms / 1000}
                     for word in result.words]
        return {"text": text, "words": normalized_words(text, words, len(audio) / SAMPLE_RATE)}

    def close(self):
        if self.model == "parakeet-ultra":
            self.session.close()
            self.native.close()


def configure_offline(runtime: Path):
    os.environ.update(HF_HUB_OFFLINE="1", HF_HUB_DISABLE_IMPLICIT_TOKEN="1", TRANSFORMERS_OFFLINE="1",
                      HF_HOME=str(runtime / "cache" / "huggingface"),
                      HF_XET_CACHE=str(runtime / "cache" / "xet"),
                      NUMBA_CACHE_DIR=str(runtime / "cache" / "numba"),
                      MPLCONFIGDIR=str(runtime / "cache" / "matplotlib"), TMPDIR=str(runtime / "tmp"))
    (runtime / "tmp").mkdir(parents=True, exist_ok=True)
    import socket
    def no_network(*args, **kwargs):
        raise OSError("The speech worker runs offline.")
    socket.socket.connect = no_network
    socket.socket.connect_ex = no_network
    socket.create_connection = no_network


def main() -> int:
    # Duplicate before redirecting fd 1: Python print(), C printf(), and package
    # subprocess output all go to stderr, while this handle alone emits JSON.
    protocol = os.fdopen(os.dup(sys.stdout.fileno()), "w", encoding="utf-8", buffering=1)
    os.dup2(sys.stderr.fileno(), sys.stdout.fileno())
    def emit(payload):
        protocol.write(json.dumps(payload, ensure_ascii=False, allow_nan=False) + "\n")
        protocol.flush()
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--models", type=Path, required=True)
    parser.add_argument("--model", choices=MODELS, required=True)
    args = parser.parse_args()
    runner = None
    try:
        configure_offline(args.runtime)
        import numpy as np
        runner = Runner(args.runtime, args.model, args.models)
        emit({"kind": "ready", "protocol": 1, "model": args.model,
              "glossarySupported": runner.glossary_supported})
    except Exception:
        traceback.print_exc(file=sys.stderr)
        emit({"kind": "ready", "protocol": 1, "model": args.model, "glossarySupported": False,
              "error": "The local speech model could not load. Check the speech runtime installation."})
        return 1
    try:
        for line in sys.stdin:
            request_id = None
            try:
                request = json.loads(line)
                request_id = request.get("id") if isinstance(request, dict) else None
                audio, language, glossary = decode_request(request)
                result = {"text": "", "words": []} if is_silent(audio) else runner.run(np.asarray(audio, dtype=np.float32), language, glossary)
                emit({"id": request_id, **result})
            except RequestError as error:
                emit({"id": request_id, "error": str(error)})
            except json.JSONDecodeError:
                emit({"id": request_id, "error": "The request JSON is invalid."})
            except Exception:
                traceback.print_exc(file=sys.stderr)
                emit({"id": request_id, "error": "Local speech recognition failed. Try this audio again."})
    finally:
        runner.close()
        protocol.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
