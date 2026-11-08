"""Summarize retained results without choosing a reference from a model's output."""
from __future__ import annotations

import csv
from datetime import datetime, timezone
import html
import json
from pathlib import Path
import statistics
import sys

ROOT = Path(sys.argv[1]).resolve()
records = [json.loads(path.read_text()) for path in sorted((ROOT / "results").glob("*.json"))]
models = sorted({record["model"] for record in records})
manifest = json.loads((ROOT / "cases.json").read_text())
reference = next(case for case in manifest["cases"] if case["id"] == "de_reported_dialogue")
decision_path = ROOT / "decision.json"
decision = json.loads(decision_path.read_text()) if decision_path.exists() else None


def pick(model: str, case: str, context: bool) -> dict | None:
    return next((record for record in records if record["model"] == model and record["stage"] == "suite"
                 and record["case"]["id"] == case and record["glossary_enabled"] == context
                 and record["repeat"] == 1 and record["status"] == "ok"), None)


def percentile(values: list[float], fraction: float) -> float:
    values = sorted(values)
    return values[min(len(values) - 1, int((len(values) - 1) * fraction))] if values else 0


summary = []
for model in models:
    candidates = [record for record in records if record["model"] == model]
    supports_context = candidates[0]["glossary_supported"]
    speech = pick(model, "de_reported_dialogue", supports_context)
    names_off = pick(model, "de_game_names", False)
    names_on = pick(model, "de_game_names", True)
    silence_off = pick(model, "de_silence", False)
    silence_on = pick(model, "de_silence", True)
    windows = [record for record in candidates if record["stage"] == "windows"
               and record["status"] == "ok" and not record["first_call"] and record["audio_seconds"] == 8]
    times = [record["inference_seconds"] for record in windows]
    long = next((record for record in candidates if record["stage"] == "long" and record["status"] == "ok"), None)
    names = lambda row: sum(row["metrics"].get("glossary_names_exact", {}).values()) if row else None
    summary.append({
        "model": model, "glossary_supported": supports_context,
        "reported_dialogue_wer": speech["metrics"]["wer"] if speech else None,
        "reported_dialogue_seconds": speech["inference_seconds"] if speech else None,
        "reported_dialogue_text": speech["text"] if speech else None,
        "names_off_of_five": names(names_off), "names_on_of_five": names(names_on),
        "window_median_seconds": statistics.median(times) if times else None,
        "window_p95_seconds": percentile(times, 0.95) if times else None,
        "window_max_seconds": max(times) if times else None,
        "window_samples": len(times),
        "continuous_seconds": long["inference_seconds"] if long else None,
        "continuous_audio_seconds": long["audio_seconds"] if long else None,
        "silence_words_off": silence_off["metrics"].get("hallucinated_words") if silence_off else None,
        "silence_words_on": silence_on["metrics"].get("hallucinated_words") if silence_on else None,
        "failed_runs": sum(record["status"] != "ok" for record in candidates),
    })

payload = {"created_at": datetime.now(timezone.utc).isoformat(), "priority": "German gameplay",
           "result_count": len(records), "models": summary, "notes": manifest["notes"], "decision": decision}
(ROOT / "summary.json").write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n")
assert json.loads((ROOT / "summary.json").read_text())["result_count"] == len(records)
with (ROOT / "summary.csv").open("w", newline="") as handle:
    writer = csv.DictWriter(handle, fieldnames=list(summary[0]))
    writer.writeheader()
    writer.writerows(summary)

lines = ["# Local German-first ASR comparison", "", "Measured on this Mac on 2026-10-31. All audio, models and raw results are retained in the selected run directory.", ""]
if decision:
    lines += ["## Recommendation", "", decision["recommendation"], "", decision["tradeoff"], "", decision["app_state"], "",
              "Before adoption:", "", *[f"- {item}" for item in decision["before_adoption"]], "",
              "The independent assessment is retained in `ASSESSMENT.md`. It used a fresh context from the host's serving family; no external AI provider reviewed repo or audio.", ""]
lines += ["## Results", "",
         "The scored natural-game passage is 16.2 seconds and 38 reference words. Word timestamps were enabled. The passage score and processing time use the glossary where supported; Ultra has no vocabulary-biasing support in this runner. Window and continuous-recording lanes use the glossary off.", "",
         "| Model / runtime | Game word error | Passage processing | 8 s window median / p95 | Names correct, no glossary / glossary | 684 s recording processing |",
         "|---|---:|---:|---:|---:|---:|"]
for row in summary:
    number = lambda value: f"{value:.2f} s" if value is not None else "unavailable"
    names = f"{row['names_off_of_five']}/5 / " + (f"{row['names_on_of_five']}/5" if row["names_on_of_five"] is not None else "unsupported")
    error = f"{row['reported_dialogue_wer']:.1%}" if row["reported_dialogue_wer"] is not None else "unavailable"
    lines.append(f"| {row['model']} | {error} | {number(row['reported_dialogue_seconds'])} | {number(row['window_median_seconds'])} / {number(row['window_p95_seconds'])} | {names} | {number(row['continuous_seconds'])} |")

lines += ["", "Timing is local inference time, not microphone/window capture-to-display latency. Window statistics include only eight-second inputs, excluding the initial four- and six-second inputs. Full Whisper and Qwen run in FP16 through MLX; Ultra uses a Q8_0 GGUF through native Metal. These are practical runtime comparisons, not isolated architecture comparisons.", "",
          "## Reported missing passage", "", "Reference copied independently from the game subtitles:", "", f"> {reference['reference']}", ""]
for row in summary:
    lines += [f"### {row['model']}", "", row["reported_dialogue_text"] or "No successful result.", ""]

lines += ["## Silence and glossary checks", "", "| Model | Words produced on 8 s digital silence, glossary off / on |", "|---|---:|"]
for row in summary:
    on = row["silence_words_on"] if row["silence_words_on"] is not None else "unsupported"
    lines.append(f"| {row['model']} | {row['silence_words_off']} / {on} |")
lines += ["", "These are raw-model checks. The current app already suppresses exact digital silence. Nonzero background audio and model-internal voice detection remain separate concerns. A prompt can cause an autoregressive model to emit glossary words on silence.", "",
          "## Pipeline check", "", "`assembly/` replays each model's saved windows through the unchanged production clipping, WindowStitcher and TranscriptAssembler. `stitching-reproduction.swift` independently reproduces a false single-word anchor that discards new words. Model replacement alone does not establish that the live app no longer loses dialogue.", "",
          "Production CoreML Turbo's captured 50-second replay and raw window trace are retained separately. They are not pooled into the standalone model timing table. The same Turbo model through MLX is included to distinguish runtime/window effects from model choice.", "",
          "## Secondary Spanish checks", "", "Three fixed Peninsular-Spanish weather recordings from OpenSLR 61 and one synthetic game-name fixture are in `audio/`. Raw word-error scores count digits versus number words as different strings; inspect those differences before interpreting Spanish accuracy. This is a compatibility check, not a Spanish-game ranking.", "",
          "## Limits", "", "- The natural-game numerical score covers one 38-word passage, not the whole game. References come from subtitles and were not independently verified by listening.",
          "- The five-name fixture is synthetic and can overstate or understate real actor performance.",
          "- The additional 90-second dialogue and 684-second continuous recording have raw transcripts but no whole-recording reference or word-error score.",
          "- Greedy standalone decoding and the app's current fallback policy are different. Model initialization, first-call effects and per-case repeats are saved in each result.",
          "- Short-window inference timing does not include capture, final-word holdback, stitching or UI work. No new model has been installed into the app.", "",
          "## Reproduce and inspect", "", "- `cases.json`: audio hashes, reference text and provenance.",
          "- `models/*.json`: exact checkpoint revisions and retained local paths.",
          "- `requirements-resolved.txt`: installed native Python package versions.",
          "- `results/*.json`: every raw transcript, word timestamp, timing and strict score.",
          "- `assembly/*.json`: the unchanged app's offline assembly of common windows.",
          "- `scripts/`: a retained copy of the benchmark source.",
          "- `sources/openslr61/`: original Spanish audio archive, transcript index and attribution.", "",
          "OpenSLR 61: https://www.openslr.org/61/ (Google, CC BY-SA 4.0). Models: https://huggingface.co/Qwen/Qwen3-ASR-1.7B ; https://huggingface.co/openai/whisper-large-v3 ; https://huggingface.co/moondream/parakeet-ultra .", ""]
(ROOT / "REPORT.md").write_text("\n".join(lines))

sections = ["<!doctype html><html lang='en'><meta charset='utf-8'><title>Local ASR comparison</title>",
            "<style>body{font:16px system-ui;max-width:1100px;margin:40px auto;padding:0 24px;color:#171717;background:#fafafa}table{border-collapse:collapse;width:100%;margin:24px 0}td,th{padding:12px;text-align:left;border-bottom:1px solid #ddd}article{background:white;padding:24px;margin:20px 0;border:1px solid #ddd;border-radius:10px}p{line-height:1.55}small{color:#666}audio{width:100%}code{font-size:13px}</style>",
            "<h1>Local German-first ASR comparison</h1><p>Same retained audio. German is the priority. Exact models, raw outputs and timings stay in the selected run directory.</p>",
            "<p><a href='REPORT.md'>Full report and limitations</a> · <a href='summary.csv'>Summary CSV</a> · <a href='summary.json'>Summary JSON</a></p>",
            "<table><tr><th>Model</th><th>Game WER</th><th>16.2 s passage</th><th>Window median / p95</th><th>Names off / on</th></tr>"]
for row in summary:
    sections.append(f"<tr><td>{html.escape(row['model'])}</td><td>{row['reported_dialogue_wer']:.1%}</td><td>{row['reported_dialogue_seconds']:.2f} s</td><td>{row['window_median_seconds']:.2f} / {row['window_p95_seconds']:.2f} s</td><td>{row['names_off_of_five']}/5 / {row['names_on_of_five'] if row['names_on_of_five'] is not None else 'unsupported'}</td></tr>")
sections += ["</table><p><small>Window times are inference cost, not end-to-end live latency. The game WER covers 38 subtitle-derived reference words. Name tests are synthetic.</small></p>"]
if decision:
    sections.insert(3, f"<article><h2>Recommendation: next German trial</h2><p>{html.escape(decision['recommendation'])}</p><p>{html.escape(decision['tradeoff'])}</p><p><strong>{html.escape(decision['app_state'])}</strong></p><p><a href='ASSESSMENT.md'>Independent assessment and evidence limits</a></p></article>")
for case in manifest["cases"]:
    sections += [f"<article><h2>{html.escape(case['id'])}</h2><audio controls preload='none' src='audio/{html.escape(Path(case['path']).name)}'></audio>"]
    if case.get("reference"):
        sections.append(f"<p><strong>Reference</strong><br>{html.escape(case['reference'])}</p>")
    elif case.get("reference") is None:
        sections.append("<p><small>No complete reference: compare by listening; no numerical accuracy claim.</small></p>")
    for model in models:
        supported = next(row["glossary_supported"] for row in summary if row["model"] == model)
        row = pick(model, case["id"], supported)
        if row:
            sections.append(f"<details><summary>{html.escape(model)} · {'glossary on' if supported else 'no glossary'} · {row['inference_seconds']:.2f} s</summary><p>{html.escape(row['text']) or '(no words)'}</p></details>")
    sections.append("</article>")
sections.append("</html>")
(ROOT / "comparison.html").write_text("\n".join(sections))
print(json.dumps(payload, ensure_ascii=False, indent=2))
