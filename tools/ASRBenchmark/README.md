# Local ASR comparison

Compare the requested models on the same retained German game audio and secondary Spanish checks. Keep audio, checkpoints, environments, logs and results on T9. These scripts run natively because MLX and the Parakeet runtime use Apple's Metal GPU. Use Docker for CPU-only code checks.

The current run root is `/Volumes/T9/VG Sentence Mining/Benchmarks/2026-10-31-local-asr`.

`download_models.py ROOT` records exact model revisions and resolves public checkpoints into the T9 cache. `prepare_cases.py ROOT` prepares common 16 kHz mono PCM inputs, subtitle-derived German reference text, existing synthetic name fixtures, silence, and three fixed Spanish OpenSLR 61 recordings. It expects the audio archives and Spanish source files recorded in the run directory.

`run_model.py ROOT MODEL --stage suite` keeps a model loaded while running glossary off/on where supported, with two repetitions. Every result is written and read back before the next case. `smoke`, `windows`, and `long` stages provide a first-case check, common four-to-eight-second windows, and the retained continuous recording. The window stage measures inference cost, not end-to-end application latency.

Raw results and prepared cases cannot be overwritten. Start a new dated run directory for another experiment. Reports can be regenerated from the retained results with `report.py ROOT`.

Models: `qwen3-asr-1.7b` with a separate word aligner, `whisper-large-v3`, `parakeet-ultra`, and `whisper-turbo-mlx` as a same-model runtime control. Production Turbo traces are retained separately. Full raw transcripts are preserved alongside normalized word/character errors and timing diagnostics.

German is the primary decision criterion. The scored game reference comes from subtitles and is not independently audio-verified. Spanish weather recordings and synthetic names are compatibility checks. Unscored game passages support listening and manual comparison; their word counts are not accuracy scores. A small fixture set cannot establish general model accuracy.

OpenSLR 61 is a Google-authored Spanish speech corpus, licensed CC BY-SA 4.0: <https://www.openslr.org/61/>. Retain its source archive, transcript index and license with the run.
