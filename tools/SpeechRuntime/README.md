# Local speech runtime

The app runs one persistent local ASR process, selected in Settings. Parakeet Ultra
uses the retained Q8_0 GGUF with transcribe.cpp Metal. Whisper Large V3 and
Qwen3-ASR 1.7B use MLX. Qwen additionally loads its forced aligner. Ultra does not
support glossary hints in this runtime; Whisper and Qwen do. Qwen is Experimental.

Native macOS tooling is required for Metal, MLX and the dylib installer. Pure
Python protocol/timing tests run in Docker:

```sh
docker run --rm --network none -v "$PWD:/workspace:ro" -w /workspace \
  python:3.12-slim python tools/SpeechRuntime/test_worker.py
```

Install from the retained benchmark assets, with no network downloads:

```sh
python3 tools/SpeechRuntime/install.py \
  --source '/Volumes/T9/VG Sentence Mining/Benchmarks/2026-10-31-local-asr' \
  --runtime '/Volumes/T9/VG Sentence Mining/SpeechRuntime' \
  --models '/Volumes/T9/VG Sentence Mining/Models'
```

The installer pins the measured package versions, uses the retained uv cache,
creates independent model paths by dereferencing snapshot symlinks, copies and
signs the native libraries, and writes `SpeechRuntime/manifest.json` with model
revisions. The environment uses the installed Homebrew Python 3.12.11 interpreter.
Keep that interpreter installed. Model assets, Python packages, caches, logs and
native libraries live on T9. The app bundles only its worker script.

Recognition uses an offline JSON-lines connection over private pipes. Audio is
mono float32 at 16 kHz, limited to 32 seconds per request. Model switches terminate
and reap the previous process before loading the next one. Capture must stop
before changing models. Model packages cannot make network connections from the
worker. FluidAudio's speaker model remains a separate shared CoreML component.

The worker preserves transcript punctuation and repairs malformed word intervals
within each audio window. Repaired intervals are approximate. This does not cure
recognition errors or hallucinations over music; review text before export.

Run the native model-switching and German/Spanish fixture check:

```sh
VG_SPEECH_INTEGRATION=1 xcrun swift test -c release
```

To retain its output, set `VG_SPEECH_REPORT_DIRECTORY` to a new existing directory
on T9. Reports refuse to overwrite existing files. Use the speech probe with
`--model parakeet-ultra`, `--model whisper-large-v3`, or
`--model qwen3-asr-1.7b` to save paced game-dialogue reports.
