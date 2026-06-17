#!/usr/bin/env python3
"""Run a matrix of transcription quality experiments and compare WER."""

from __future__ import annotations

import argparse
import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Sequence


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_TSV = (
  REPO_ROOT
  / "benchmark-data/common-voice/prepared/librispeech_clean/test-limit200-seed20260506/test.tsv"
)
DEFAULT_CLIPS = DEFAULT_TSV.parent / "clips"
DEFAULT_GLOSSARY = DEFAULT_TSV.parent / "eval_proper_noun_glossary.txt"
DEFAULT_BINARY = REPO_ROOT / ".build/debug/Voicey"
DEFAULT_OUTPUT = REPO_ROOT / "benchmark-results/quality-matrix"


@dataclass(frozen=True)
class Variant:
  id: str
  description: str
  model: str
  extra_args: tuple[str, ...] = ()
  clips_dir: Path | None = None
  metric_note: str = ""


def load_benchmark_module():
  script_path = REPO_ROOT / "scripts/benchmark_common_voice.py"
  spec = importlib.util.spec_from_file_location("benchmark_common_voice", script_path)
  if spec is None or spec.loader is None:
    raise RuntimeError(f"Unable to load {script_path}")
  module = importlib.util.module_from_spec(spec)
  sys.modules[spec.name] = module
  spec.loader.exec_module(module)
  return module


def default_variants(glossary_file: Path) -> list[Variant]:
  glossary = ("--glossary-file", str(glossary_file))
  return [
    Variant("baseline-1.7b-raw", "1.7b raw ASR", "qwen3-asr-1.7b-bf16"),
    Variant(
      "baseline-1.7b-proc",
      "1.7b + voicey-text post-process",
      "qwen3-asr-1.7b-bf16",
      ("--post-process",),
    ),
    Variant(
      "lang-english-1.7b-raw",
      "1.7b raw + English language hint",
      "qwen3-asr-1.7b-bf16",
      ("--language", "english"),
    ),
    Variant(
      "model-0.6b-raw",
      "0.6b raw ASR",
      "qwen3-asr-0.6b-6bit",
    ),
    Variant(
      "repair-glossary-1.7b",
      "1.7b + post-process + fuzzy vocabulary repair (no decoder steer)",
      "qwen3-asr-1.7b-bf16",
      ("--post-process", "--vocabulary-repair", *glossary),
    ),
    Variant(
      "steer-glossary-1.7b-raw",
      "1.7b raw + decoder glossary steering",
      "qwen3-asr-1.7b-bf16",
      ("--glossary-steer", *glossary),
    ),
    Variant(
      "steer-glossary-1.7b-proc",
      "1.7b + decoder glossary + post-process",
      "qwen3-asr-1.7b-bf16",
      ("--post-process", "--glossary-steer", *glossary),
    ),
    Variant(
      "itn-1.7b",
      "1.7b + post-process + deterministic ITN",
      "qwen3-asr-1.7b-bf16",
      ("--post-process", "--itn"),
      metric_note="ITN improves modern prose; may raise WER vs archaic LibriSpeech references.",
    ),
    Variant(
      "audio-quiet-1.7b-raw",
      "1.7b raw on −12 dB clips",
      "qwen3-asr-1.7b-bf16",
      clips_dir=Path("__audio_quiet__"),
    ),
    Variant(
      "audio-noisy-1.7b-raw",
      "1.7b raw on noise-mixed clips",
      "qwen3-asr-1.7b-bf16",
      clips_dir=Path("__audio_noisy__"),
    ),
  ]


def prepare_audio_variant(source_dir: Path, destination_dir: Path, mode: str) -> None:
  if destination_dir.exists():
    shutil.rmtree(destination_dir)
  destination_dir.mkdir(parents=True)

  for wav in sorted(source_dir.glob("*.wav")):
    target = destination_dir / wav.name
    if mode == "quiet":
      filter_args = ["-filter:a", "volume=-12dB"]
    elif mode == "noisy":
      filter_args = ["-filter:a", "volume=-12dB,afftdn=nf=-25"]
    else:
      raise ValueError(f"unknown audio mode: {mode}")

    command = [
      "ffmpeg",
      "-nostdin",
      "-hide_banner",
      "-loglevel",
      "error",
      "-y",
      "-i",
      str(wav),
      *filter_args,
      "-ac",
      "1",
      "-ar",
      "16000",
      str(target),
    ]
    subprocess.run(command, check=True)


def run_variant(
  variant: Variant,
  *,
  binary: Path,
  tsv_path: Path,
  clips_dir: Path,
  limit: int,
  timeout_seconds: float,
  temp_root: Path,
) -> dict[str, Any]:
  benchmark = load_benchmark_module()
  samples, _ = benchmark.sample_common_voice_rows(
    tsv_path,
    clips_dir,
    limit=limit,
    seed=20260506,
    skip_missing=False,
  )
  sample_tsv = temp_root / f"{variant.id}.tsv"
  benchmark.write_batch_sample_tsv(sample_tsv, samples)

  effective_clips = clips_dir
  if variant.clips_dir is not None:
    if variant.clips_dir.name == "__audio_quiet__":
      effective_clips = temp_root / f"{variant.id}-clips"
      prepare_audio_variant(clips_dir, effective_clips, "quiet")
    elif variant.clips_dir.name == "__audio_noisy__":
      effective_clips = temp_root / f"{variant.id}-clips"
      prepare_audio_variant(clips_dir, effective_clips, "noisy")
    else:
      effective_clips = variant.clips_dir

  command = [
    str(binary),
    "benchmark-transcribe-batch",
    "--model",
    variant.model,
    "--tsv",
    str(sample_tsv),
    "--clips-dir",
    str(effective_clips),
    *variant.extra_args,
  ]

  started = time.time()
  completed = subprocess.run(
    command,
    check=False,
    capture_output=True,
    text=True,
    timeout=timeout_seconds,
  )
  elapsed = time.time() - started
  if completed.returncode != 0:
    return {
      "id": variant.id,
      "description": variant.description,
      "model": variant.model,
      "status": "error",
      "error": completed.stderr.strip() or completed.stdout.strip(),
      "elapsed_seconds": elapsed,
      "metric_note": variant.metric_note,
    }

  predictions = [json.loads(line) for line in completed.stdout.splitlines() if line.strip()]
  records: list[dict[str, Any]] = []
  for prediction in predictions:
    audio = prediction["audio"]
    sample = next(item for item in samples if item.relative_audio_path == audio)
    raw_prediction = prediction.get("rawText", prediction["text"])
    processed_prediction = prediction["text"]
    processed_metrics = benchmark.compute_text_metrics(
      reference=sample.reference,
      prediction=processed_prediction,
      case_sensitive=False,
      keep_punctuation=False,
    )
    record: dict[str, Any] = {
      "audio": audio,
      "reference_words": processed_metrics.reference_words,
      "word_errors": processed_metrics.word_errors,
      "wer": processed_metrics.wer,
      "char_errors": processed_metrics.char_errors,
      "reference_chars": processed_metrics.reference_chars,
      "processing_seconds": prediction.get("processingSeconds", 0.0),
    }
    if "rawText" in prediction:
      raw_metrics = benchmark.compute_text_metrics(
        reference=sample.reference,
        prediction=raw_prediction,
        case_sensitive=False,
        keep_punctuation=False,
      )
      record.update(
        {
          "raw_wer": raw_metrics.wer,
          "raw_word_errors": raw_metrics.word_errors,
          "post_process_changed": (
            raw_metrics.normalized_prediction != processed_metrics.normalized_prediction
          ),
        }
      )
    records.append(record)

  summaries = benchmark.summarize_results(
    [{"model": variant.id, **record} for record in records if "error" not in record]
  )
  summary = summaries.get(variant.id, {})
  return {
    "id": variant.id,
    "description": variant.description,
    "model": variant.model,
    "status": "ok",
    "clips": len(records),
    "elapsed_seconds": elapsed,
    "raw_wer": summary.get("raw_wer", summary.get("wer")),
    "proc_wer": summary.get("wer"),
    "delta": summary.get("post_process_wer_delta"),
    "changed_clips": summary.get("post_process_changed_clips", 0),
    "cer": summary.get("cer"),
    "rtf": summary.get("real_time_factor"),
    "metric_note": variant.metric_note,
    "extra_args": list(variant.extra_args),
  }


def write_summary_markdown(path: Path, results: Sequence[dict[str, Any]]) -> None:
  lines = [
    "# Transcription quality matrix",
    "",
    "| Variant | Status | raw WER | proc WER | delta | changed | CER | RTF | seconds |",
    "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
  ]
  for result in results:
    if result.get("status") != "ok":
      lines.append(
        f"| {result['id']} | error | — | — | — | — | — | — | {result.get('elapsed_seconds', 0):.1f} |"
      )
      continue
    lines.append(
      "| "
      + " | ".join(
        [
          result["id"],
          "ok",
          format_rate(result.get("raw_wer")),
          format_rate(result.get("proc_wer")),
          format_rate(result.get("delta")),
          str(result.get("changed_clips", 0)),
          format_rate(result.get("cer")),
          format_rate(result.get("rtf")),
          f"{result.get('elapsed_seconds', 0):.1f}",
        ]
      )
      + " |"
    )

  lines.extend(["", "## Notes", ""])
  for result in results:
    note = result.get("metric_note")
    if note:
      lines.append(f"- **{result['id']}:** {note}")
    if result.get("status") == "error":
      lines.append(f"- **{result['id']}:** {result.get('error', 'unknown error')}")

  path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def format_rate(value: Any) -> str:
  if value is None:
    return "—"
  return f"{float(value):.4f}"


def build_parser() -> argparse.ArgumentParser:
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument("--tsv", type=Path, default=DEFAULT_TSV)
  parser.add_argument("--clips-dir", type=Path, default=DEFAULT_CLIPS)
  parser.add_argument("--glossary-file", type=Path, default=DEFAULT_GLOSSARY)
  parser.add_argument("--binary", type=Path, default=DEFAULT_BINARY)
  parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT)
  parser.add_argument("--limit", type=int, default=200)
  parser.add_argument("--timeout-seconds", type=float, default=3600.0)
  parser.add_argument(
    "--variants",
    nargs="*",
    help="Subset of variant ids (default: all).",
  )
  return parser


def main(argv: Sequence[str] | None = None) -> int:
  args = build_parser().parse_args(argv)
  if not args.binary.is_file():
    print(f"error: missing Voicey binary at {args.binary}", file=sys.stderr)
    return 1
  if not args.tsv.is_file() or not args.clips_dir.is_dir():
    print("error: missing prepared TSV/clips — run prepare_librispeech_sample.py first", file=sys.stderr)
    return 1

  variants = default_variants(args.glossary_file)
  if args.variants:
    wanted = set(args.variants)
    variants = [variant for variant in variants if variant.id in wanted]
    missing = wanted - {variant.id for variant in variants}
    if missing:
      print(f"error: unknown variants: {', '.join(sorted(missing))}", file=sys.stderr)
      return 1

  timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
  output_dir = args.output_dir / timestamp
  output_dir.mkdir(parents=True, exist_ok=True)

  results: list[dict[str, Any]] = []
  with tempfile.TemporaryDirectory(prefix="voicey-quality-matrix-") as temp_dir:
    temp_root = Path(temp_dir)
    for variant in variants:
      print(f"[matrix] {variant.id}: {variant.description}", flush=True)
      result = run_variant(
        variant,
        binary=args.binary,
        tsv_path=args.tsv,
        clips_dir=args.clips_dir,
        limit=args.limit,
        timeout_seconds=args.timeout_seconds,
        temp_root=temp_root,
      )
      results.append(result)
      (output_dir / f"{variant.id}.json").write_text(
        json.dumps(result, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
      )
      if result.get("status") == "ok":
        print(
          f"  raw={format_rate(result.get('raw_wer'))} "
          f"proc={format_rate(result.get('proc_wer'))} "
          f"changed={result.get('changed_clips', 0)}",
          flush=True,
        )
      else:
        print(f"  error: {result.get('error')}", flush=True)

  payload = {
    "created_at": timestamp,
    "tsv": str(args.tsv),
    "clips_dir": str(args.clips_dir),
    "limit": args.limit,
    "results": results,
  }
  summary_json = output_dir / "summary.json"
  summary_json.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
  write_summary_markdown(output_dir / "summary.md", results)
  print(f"Summary: {summary_json}")
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
