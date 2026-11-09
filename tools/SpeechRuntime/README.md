# Local speech runtime

## In-app installation

Choose **Set up speech recognition** on the welcome screen, or open
**Settings → Speech**. Choose **Install** beside the model you need.
Downloads default to `~/Library/Application Support/VG Sentence Mining`.
No Homebrew, Python installation, terminal commands, or developer tools are required.
An internet connection is required during installation and the first model load.

Each model has a separate Python environment under `SpeechRuntime/Environments`.
The installer uses the checksum-verified [uv 0.13.7 release](https://github.com/astral-sh/uv/releases/tag/0.13.7)
to obtain a private Python 3.12.11 and hash-locked wheels from PyPI.
Parakeet uses the published [transcribe-cpp 0.4.1](https://pypi.org/project/transcribe-cpp/0.4.1/) native Metal wheel.
Other runtime dependencies are installed only for their selected model.
The bundled `Requirements/*.txt` files pin all packages and hashes; `.in` files record direct requirements.

Model downloads use pinned Hugging Face revisions. The installer checks file sizes
and LFS SHA-256 hashes before publishing model entries in `manifest.json`.
Qwen installs its aligner together with its recognizer. Unrelated model entries
and older manually installed runtimes are preserved.
Cancellation leaves partial downloads available for retry. Failed installations
do not publish a new model entry. An exclusive folder lock prevents concurrent installations.
Diagnostics are in `SpeechRuntime/Logs/installation.log`.

Move the entire speech folder to relocate it, then choose it in Settings.
The in-app installer uses relative interpreter links. It does not modify your system Python or shell settings.

Run the offline installer and worker tests:

```sh
docker run --rm --network none -v "$PWD:/workspace:ro" -w /workspace \
  python:3.12-slim python -m unittest discover -s tools/SpeechRuntime -p 'test_*.py'
```

The optional native installation check downloads only Parakeet into the configured
speech folder and loads the recognition and shared models:

```sh
VG_INSTALL_INTEGRATION=1 xcrun swift test -c release --filter modelInstallationIntegration
```

## Retained offline assets

The app runs one persistent local ASR process, selected in Settings. Parakeet Ultra
uses the retained Q8_0 GGUF with transcribe.cpp Metal. Whisper Large V3 and
Qwen3-ASR 1.7B use MLX. Qwen additionally loads its forced aligner. Ultra does not
support glossary hints in this runtime; Whisper and Qwen do. Qwen is Experimental.

Enable capture languages in Settings. Whisper supports every offered language.
Ultra excludes Indonesian, Turkish, and Vietnamese. Qwen is limited to English,
French, German, Italian, Portuguese, Russian, and Spanish because word timings
require its forced aligner. The worker rejects unsupported model/language pairs
before inference. Enabling another language reuses the installed multilingual
weights; it does not download another model.

Native macOS tooling is required for Metal, MLX and the dylib installer. Pure
Python protocol/timing tests run in Docker:

```sh
docker run --rm --network none -v "$PWD:/workspace:ro" -w /workspace \
  python:3.12-slim python tools/SpeechRuntime/test_worker.py
```

Install from the retained benchmark assets, with no network downloads:

```sh
python3 tools/SpeechRuntime/install.py \
  --source /path/to/retained-benchmark \
  --destination "$HOME/Library/Application Support/VG Sentence Mining"
```

This is an example destination. Choose any writable speech folder on your Mac
or an external drive. The installer creates `Models` and `SpeechRuntime` inside
it. Select that one parent folder in **Settings → Transcription** and reload
the model. The app remembers your choice. Folder changes are disabled during
capture or model loading.

Move the whole speech folder to change disks. Keep the model folder's installed layout: each model has a
revision subfolder; the native model also contains its GGUF file. New manifests
store model paths relative to this folder. The app also rebases older absolute
manifest paths onto the selected folder, including the word aligner. Recognition
does not fall back to a model left behind in the original location.

The installer pins the measured package versions, uses the retained uv cache,
creates independent model paths by dereferencing snapshot symlinks, copies and
signs the native libraries, and writes `SpeechRuntime/manifest.json` with model
revisions. The environment uses the installed Homebrew Python 3.12.11 interpreter.
Keep that interpreter installed. Model assets, Python packages, caches, logs and
native libraries live in your speech folder. The app bundles only its worker script.

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

The probe and integration tests read the app's saved speech folder. Set
`VG_SPEECH_DIRECTORY` for a separate installation;
the probe also accepts `--speech-folder PATH`.

To retain its output, set `VG_SPEECH_REPORT_DIRECTORY` to a new existing directory.
Reports refuse to overwrite existing files. Use the speech probe with
`--model parakeet-ultra`, `--model whisper-large-v3`, or
`--model qwen3-asr-1.7b` to save paced game-dialogue reports.
