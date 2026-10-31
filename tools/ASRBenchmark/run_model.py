"""Run one local model at a time; retain every output before starting the next case."""
from __future__ import annotations

import argparse
from dataclasses import asdict, is_dataclass
from datetime import datetime, timezone
import importlib
import json
import os
from pathlib import Path
import resource
import sys
import time
import unicodedata


def normalized(text: str) -> str:
    text = unicodedata.normalize("NFKC", text).casefold()
    return " ".join("".join(" " if unicodedata.category(c)[0] in "PS" else c for c in text).split())


def json_value(value):
    if is_dataclass(value):
        return asdict(value)
    if hasattr(value, "tolist"):
        return value.tolist()
    if hasattr(value, "item"):
        return value.item()
    raise TypeError(type(value).__name__)


def write_verified(path: Path, payload: dict) -> None:
    if path.exists():
        raise FileExistsError(f"Retained result already exists: {path}. Use a new run directory.")
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2, default=json_value) + "\n")
    temporary.replace(path)
    assert json.loads(path.read_text())["model"] == payload["model"]


class Runner:
    def __init__(self, root: Path, name: str):
        self.name = name
        self.first_call = True
        self.glossary_supported = True
        metadata = json.loads((root / "models" / f"{name}.json").read_text())
        if metadata["status"] != "downloaded":
            raise RuntimeError(metadata)
        self.metadata = metadata
        path = metadata["path"]
        if name.startswith("whisper"):
            import mlx_whisper
            self.transcribe = mlx_whisper.transcribe
        elif name.startswith("qwen"):
            import mlx.core as mx
            from mlx_qwen3_asr import ForcedAligner, Session
            self.session = Session(model=path, dtype=mx.float16)
            aligner = json.loads((root / "models" / "qwen3-aligner.json").read_text())
            self.aligner = ForcedAligner(model_path=aligner["path"], dtype=mx.float16, backend="mlx")
        else:
            source = root / "runtimes" / "transcribe.cpp"
            os.environ["TRANSCRIBE_LIBRARY"] = str(root / "runtimes" / "transcribe-build" / "src" / "libtranscribe.dylib")
            sys.path.insert(0, str(source / "bindings" / "python" / "src"))
            import transcribe_cpp
            self.native = transcribe_cpp.Model(path, backend="metal")
            self.session = self.native.session()
            self.glossary_supported = self.native.supports("vocabulary")

    def run(self, audio, language: str, glossary: list[str]) -> dict:
        if self.name.startswith("whisper"):
            raw = self.transcribe(audio, path_or_hf_repo=self.metadata["path"], language=language,
                                  task="transcribe", fp16=True, word_timestamps=True,
                                  initial_prompt=", ".join(glossary) or None,
                                  condition_on_previous_text=False, temperature=0.0, verbose=None)
            words = [word for segment in raw["segments"] for word in segment.get("words", [])]
            words = [{"text": word["word"], "start": word["start"], "end": word["end"]} for word in words]
            return {"text": raw["text"], "words": words, "raw": raw}
        if self.name.startswith("qwen"):
            result = self.session.transcribe((audio, 16000), language={"de": "German", "es": "Spanish"}[language],
                                             context=", ".join(glossary), return_timestamps=True,
                                             forced_aligner=self.aligner, return_chunks=True, max_new_tokens=2048)
            return {"text": result.text, "words": result.segments or [], "raw": asdict(result)}
        result = self.session.run(audio, language=language, timestamps="word",
                                  vocabulary=glossary if glossary and self.glossary_supported else None)
        return {"text": result.text,
                "words": [{"text": word.text, "start": word.t0_ms / 1000, "end": word.t1_ms / 1000} for word in result.words],
                "raw": asdict(result)}


def score(case: dict, text: str) -> dict:
    import jiwer
    reference = case.get("reference")
    result = {}
    if reference is not None:
        ref, hypothesis = normalized(reference), normalized(text)
        if ref:
            metrics = jiwer.process_words(ref, hypothesis)
            result.update(wer=metrics.wer, cer=jiwer.cer(ref, hypothesis), substitutions=metrics.substitutions,
                          deletions=metrics.deletions, insertions=metrics.insertions, reference_words=len(ref.split()))
        else:
            result["hallucinated_words"] = len(hypothesis.split())
    for key in ("coverage_phrases", "glossary_names"):
        if key in case:
            result[key + "_exact"] = {phrase: normalized(phrase) in normalized(text) for phrase in case[key]}
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    parser.add_argument("model")
    parser.add_argument("--stage", choices=["smoke", "suite", "windows", "long"], default="suite")
    args = parser.parse_args()
    root = args.root.resolve()
    os.environ["HF_HOME"] = str(root / "cache" / "huggingface")
    os.environ["HF_XET_CACHE"] = str(root / "cache" / "xet")
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["HF_HUB_DISABLE_IMPLICIT_TOKEN"] = "1"
    os.environ["NUMBA_CACHE_DIR"] = str(root / "cache" / "numba")
    os.environ["MPLCONFIGDIR"] = str(root / "cache" / "matplotlib")
    os.environ["TMPDIR"] = str(root / "tmp")
    (root / "tmp").mkdir(exist_ok=True)
    import numpy as np
    import soundfile as sf

    manifest = json.loads((root / "cases.json").read_text())
    setup_start = time.perf_counter()
    runner = Runner(root, args.model)
    setup_seconds = time.perf_counter() - setup_start
    cases = manifest["cases"]
    if args.stage == "smoke":
        cases = cases[:1]
    elif args.stage == "long":
        cases = [{"id": "de_continuous", "path": manifest["continuous_audio"], "language": "de", "reference": None}]
    elif args.stage == "windows":
        cases = [case for case in cases if case["id"] == "de_reported_context"]

    for case in cases:
        audio, rate = sf.read(case["path"], dtype="float32")
        assert rate == 16000 and audio.ndim == 1
        if args.stage == "windows":
            jobs = [(end, audio[max(0, int((end - 8) * rate)):int(end * rate)]) for end in np.arange(4, len(audio) / rate + 0.01, 2)]
        else:
            jobs = [(None, audio)]
        contexts = [False, True] if runner.glossary_supported and args.stage == "suite" else [False]
        for enabled in contexts:
            repeats = range(2) if args.stage == "suite" else range(1)
            for repeat in repeats:
                for end, samples in jobs:
                    first = runner.first_call
                    runner.first_call = False
                    start = time.perf_counter()
                    try:
                        result = runner.run(samples, case["language"], manifest["glossary"] if enabled else [])
                        duration = time.perf_counter() - start
                        payload = {"status": "ok", **result, "metrics": score(case, result["text"]) if end is None else {}}
                    except Exception as error:
                        duration = time.perf_counter() - start
                        payload = {"status": "failed", "error": f"{type(error).__name__}: {error}"}
                    payload.update(model=args.model, model_metadata=runner.metadata, stage=args.stage, case=case,
                                   glossary_enabled=enabled, glossary_supported=runner.glossary_supported,
                                   repeat=repeat, first_call=first, setup_seconds=setup_seconds,
                                   inference_seconds=duration, audio_seconds=len(samples) / rate,
                                   window_end=end, recorded_at=datetime.now(timezone.utc).isoformat(),
                                   peak_process_bytes=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)
                    words = payload.get("words", [])
                    payload["word_count"] = len(words)
                    payload["valid_word_times"] = sum(0 <= word["start"] < word["end"] <= len(samples) / rate + 0.1 for word in words)
                    name = f"{args.stage}-{args.model}-{case['id']}-context{int(enabled)}-r{repeat}"
                    if end is not None:
                        name += f"-end{end:.0f}"
                    write_verified(root / "results" / f"{name}.json", payload)
                    print(json.dumps({"file": name, "status": payload["status"], "seconds": duration,
                                      "text": payload.get("text"), "metrics": payload.get("metrics"), "error": payload.get("error")}, ensure_ascii=False), flush=True)
                    if payload["status"] != "ok":
                        return


if __name__ == "__main__":
    main()
