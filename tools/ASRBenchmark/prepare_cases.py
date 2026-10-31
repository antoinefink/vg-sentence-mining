"""Retain common PCM inputs and independent references for the local ASR comparison."""
import hashlib
import io
import json
from pathlib import Path
import shutil
import sys
import zipfile

import numpy as np
import soundfile as sf

ROOT = Path(sys.argv[1]).resolve()
if (ROOT / "cases.json").exists():
    raise SystemExit("This run already has retained cases. Use a new run directory to prepare another set.")
REPO = Path(__file__).resolve().parents[2]
AUDIO = ROOT / "audio"
AUDIO.mkdir(parents=True, exist_ok=True)
ARCHIVE = Path("/Volumes/T9/VG Sentence Mining/Test Media/witcher-2026-10-31-missing-dialogue")
cases = []


def add(name, samples, rate, language, reference, source, category, **extra):
    if samples.ndim > 1:
        samples = samples.mean(axis=1)
    if rate != 16000:
        from scipy.signal import resample_poly
        from math import gcd
        divisor = gcd(rate, 16000)
        samples = resample_poly(samples, 16000 // divisor, rate // divisor)
    path = AUDIO / f"{name}.wav"
    sf.write(path, samples, 16000, subtype="PCM_16")
    case = {"id": name, "path": str(path), "language": language, "reference": reference,
            "source": source, "category": category, "duration_seconds": len(samples) / 16000,
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), **extra}
    cases.append(case)


game, rate = sf.read(ARCHIVE / "reported-dialogue-19h48m44s.wav", dtype="float32")
add("de_reported_dialogue", game[int(15.2 * rate):int(31.4 * rate)], rate, "de",
    "Ich kann meine Truppen nicht auseinanderziehen. Die temerische Armee mögen wir besiegt haben, aber die Bevölkerung ist noch da, die könnte zu den Waffen greifen. Also kann ich wegen des Monsters entweder Däumchen drehen oder einen Experten beauftragen.",
    "User game capture 2026-10-31 around 19:49; reference manually copied from retained in-game subtitle frame at 19:49:05.",
    "game", reference_status="subtitle-derived, not independently audio-verified",
    coverage_phrases=["Ich kann meine Truppen nicht auseinanderziehen", "die könnte zu den Waffen greifen", "Däumchen drehen"])
add("de_reported_context", game, rate, "de", None, "Same capture, complete 50-second context", "unscored_game")
for language, fixture, reference in [
    ("de", "german", "Geralt von Riva reist mit Yennefer nach Kaer Morhen. Ciri wartet dort auf Vesemir."),
    ("es", "spanish", "Geralt de Rivia viaja con Yennefer a Kaer Morhen. Ciri espera allí a Vesemir."),
]:
    samples, rate = sf.read(REPO / "Tests" / "MiningSpeechTests" / "Fixtures" / f"{fixture}.wav", dtype="float32")
    add(f"{language}_game_names", samples, rate, language, reference, "Existing synthetic app fixture", "synthetic_names",
        reference_status="known TTS input; not representative of natural game speech",
        glossary_names=["Geralt", "Yennefer", "Kaer Morhen", "Ciri", "Vesemir"])
add("de_silence", np.zeros(8 * 16000, dtype=np.float32), 16000, "de", "", "Digital silence", "silence")

download_notes = ["FLEURS and VoxPopuli viewer endpoints returned HTTP 500; use the smaller OpenSLR 61 Spanish weather corpus."]
spanish_source = ROOT / "sources" / "openslr61"
with zipfile.ZipFile(spanish_source / "es_weather_messages.zip") as archive:
    lines = (spanish_source / "es_es_line_index_weather.tsv").read_text(encoding="utf-8").splitlines()[:3]
    for index, line in enumerate(lines):
        file_id, reference = line.split("\t", 1)
        member = next(name for name in archive.namelist() if Path(name).stem == file_id)
        samples, rate = sf.read(io.BytesIO(archive.read(member)), dtype="float32")
        add(f"es_weather_{index}", samples, rate, "es", reference,
            {"dataset": "OpenSLR 61", "url": "https://www.openslr.org/61/", "file_id": file_id,
             "audio_url": "https://openslr.trmal.net/resources/61/es_weather_messages.zip", "license": "CC BY-SA 4.0"},
            "natural_speech", reference_status="published reference; narrow weather-domain smoke test")

shutil.copy2(ARCHIVE / "session.wav", AUDIO / "de_continuous.wav")
latest = sorted(ARCHIVE.parent.glob("witcher-latest-dialogue-*/session.wav"))
if latest:
    samples, rate = sf.read(latest[-1], dtype="float32")
    add("de_additional_dialogue", samples[-90 * rate:], rate, "de", None,
        f"Last 90 seconds of additional user-approved recording: {latest[-1]}", "unscored_game")
payload = {"cases": cases, "notes": download_notes,
           "continuous_audio": str(AUDIO / "de_continuous.wav"),
           "glossary": ["Geralt", "Ciri", "Yennefer", "Vesemir", "Kaer Morhen", "Weißgarten", "Plötze"]}
destination = ROOT / "cases.json"
destination.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n")
assert len(json.loads(destination.read_text())["cases"]) == len(cases)
print(json.dumps({"cases": [(case["id"], case["duration_seconds"]) for case in cases], "notes": download_notes}, ensure_ascii=False), flush=True)
