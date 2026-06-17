#!/usr/bin/env python3
"""Compare Qwen vs Apple Speech on a prepared WAV corpus and score rerank ceilings."""

from __future__ import annotations

import argparse
import importlib.util
import json
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Sequence


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_TSV = (
  REPO_ROOT
  / "benchmark-data/common-voice/prepared/cmkfm9fbl00nto0070sdcrak2/test-limit200-seed20260506/test.tsv"
)
DEFAULT_CLIPS = DEFAULT_TSV.parent / "clips"
DEFAULT_BINARY = REPO_ROOT / ".build/debug/Voicey"
DEFAULT_APPLE_APP = REPO_ROOT / "Benchmarks/AppleSpeech/voicey-apple-speech-benchmark.app"
DEFAULT_APPLE_BINARY = DEFAULT_APPLE_APP / "Contents/MacOS/voicey-apple-speech-benchmark"
DEFAULT_OUTPUT = REPO_ROOT / "benchmark-results/apple-speech-rerank"


def load_benchmark_module():
  script_path = REPO_ROOT / "scripts/benchmark_common_voice.py"
  spec = importlib.util.spec_from_file_location("benchmark_common_voice", script_path)
  if spec is None or spec.loader is None:
    raise RuntimeError(f"Unable to load {script_path}")
  module = importlib.util.module_from_spec(spec)
  sys.modules[spec.name] = module
  spec.loader.exec_module(module)
  return module


@dataclass(frozen=True)
class Prediction:
  audio: str
  text: str


def build_apple_binary(force: bool) -> Path:
  app_bundle = DEFAULT_APPLE_APP
  binary = DEFAULT_APPLE_BINARY
  if binary.is_file() and app_bundle.is_dir() and not force:
    return app_bundle
  completed = subprocess.run(
    ["make", "build-apple-speech-benchmark"],
    cwd=REPO_ROOT,
    capture_output=True,
    text=True,
    check=False,
  )
  if completed.returncode != 0:
    raise RuntimeError(
      "swift build failed for Apple Speech benchmark:\n"
      + (completed.stderr or completed.stdout)
    )
  if not binary.is_file():
    raise RuntimeError(f"Missing Apple Speech binary at {binary}")
  return app_bundle


def run_qwen_batch(
  *,
  binary: Path,
  sample_tsv: Path,
  clips_dir: Path,
  model: str,
  language: str | None,
) -> list[Prediction]:
  command = [
    str(binary),
    "benchmark-transcribe-batch",
    "--tsv",
    str(sample_tsv),
    "--clips-dir",
    str(clips_dir),
    "--model",
    model,
  ]
  if language:
    command.extend(["--language", language])
  completed = subprocess.run(command, capture_output=True, text=True, timeout=3600, check=False)
  if completed.returncode != 0:
    raise RuntimeError(completed.stderr.strip() or completed.stdout.strip())
  predictions: list[Prediction] = []
  for line in completed.stdout.splitlines():
    if not line.strip():
      continue
    payload = json.loads(line)
    predictions.append(
      Prediction(
        audio=payload["audio"],
        text=str(payload.get("rawText") or payload["text"]),
      )
    )
  return predictions


def run_apple_batch(
  *,
  app_bundle: Path,
  sample_tsv: Path,
  clips_dir: Path,
) -> list[Prediction]:
  output_path = sample_tsv.parent / "apple-speech.ndjson"
  if output_path.is_file():
    output_path.unlink()
  command = [
    "open",
    "-W",
    "-n",
    str(app_bundle),
    "--args",
    "--tsv",
    str(sample_tsv),
    "--clips-dir",
    str(clips_dir),
    "--output",
    str(output_path),
  ]
  completed = subprocess.run(command, capture_output=True, text=True, timeout=3600, check=False)
  if completed.returncode != 0:
    detail = (completed.stderr or completed.stdout or f"exit {completed.returncode}").strip()
    raise RuntimeError(f"Apple Speech batch failed: {detail}")
  if not output_path.is_file():
    raise RuntimeError(
      "Apple Speech produced no output. Grant Speech Recognition to "
      f"{app_bundle.name} in System Settings → Privacy & Security."
    )
  predictions: list[Prediction] = []
  for line in output_path.read_text(encoding="utf-8").splitlines():
    if not line.strip():
      continue
    payload = json.loads(line)
    predictions.append(Prediction(audio=payload["audio"], text=str(payload["text"])))
  return predictions


def aggregate_wer(
  benchmark,
  samples,
  predictions: dict[str, str],
) -> tuple[float, int]:
  total_ref = 0
  total_err = 0
  perfect = 0
  for sample in samples:
    prediction = predictions.get(sample.relative_audio_path)
    if prediction is None:
      raise RuntimeError(f"Missing prediction for {sample.relative_audio_path}")
    metrics = benchmark.compute_text_metrics(
      reference=sample.reference,
      prediction=prediction,
      case_sensitive=False,
      keep_punctuation=False,
    )
    total_ref += metrics.reference_words
    total_err += metrics.word_errors
    if metrics.wer == 0:
      perfect += 1
  wer = total_err / total_ref if total_ref else 0.0
  return wer, perfect


def oracle_pick(
  benchmark,
  samples,
  qwen: dict[str, str],
  apple: dict[str, str],
) -> dict[str, str]:
  picked: dict[str, str] = {}
  for sample in samples:
    q_metrics = benchmark.compute_text_metrics(
      reference=sample.reference,
      prediction=qwen[sample.relative_audio_path],
      case_sensitive=False,
      keep_punctuation=False,
    )
    a_metrics = benchmark.compute_text_metrics(
      reference=sample.reference,
      prediction=apple[sample.relative_audio_path],
      case_sensitive=False,
      keep_punctuation=False,
    )
    picked[sample.relative_audio_path] = (
      qwen[sample.relative_audio_path]
      if q_metrics.wer <= a_metrics.wer
      else apple[sample.relative_audio_path]
    )
  return picked


def write_summary_markdown(path: Path, payload: dict[str, Any]) -> None:
  rows = payload["systems"]
  lines = [
    "# Apple Speech rerank eval",
    "",
    f"Corpus: `{payload['tsv']}`",
    f"Clips: {payload['limit']}",
    "",
    "| system | WER | perfect clips |",
    "| --- | ---: | ---: |",
  ]
  for row in rows:
    lines.append(
      f"| {row['id']} | {row['wer']:.4f} | {row['perfect']}/{payload['limit']} |"
    )
  lines.extend(["", "## Notes", "", "- `oracle-pick` chooses the lower-WER hypothesis per clip (ceiling)."])
  path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def build_parser() -> argparse.ArgumentParser:
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument("--tsv", type=Path, default=DEFAULT_TSV)
  parser.add_argument("--clips-dir", type=Path, default=DEFAULT_CLIPS)
  parser.add_argument("--binary", type=Path, default=DEFAULT_BINARY)
  parser.add_argument("--model", default="qwen3-asr-1.7b-bf16")
  parser.add_argument("--language", default="english")
  parser.add_argument("--limit", type=int, default=50)
  parser.add_argument("--seed", type=int, default=20260506)
  parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT)
  parser.add_argument("--rebuild-apple", action="store_true")
  return parser


def main(argv: Sequence[str] | None = None) -> int:
  args = build_parser().parse_args(argv)
  if not args.binary.is_file():
    print(f"error: missing Voicey binary at {args.binary}", file=sys.stderr)
    return 1
  if not args.tsv.is_file() or not args.clips_dir.is_dir():
    print("error: missing prepared TSV/clips", file=sys.stderr)
    return 1

  benchmark = load_benchmark_module()
  samples, _ = benchmark.sample_common_voice_rows(
    args.tsv,
    args.clips_dir,
    limit=args.limit,
    seed=args.seed,
    skip_missing=False,
  )

  with tempfile.TemporaryDirectory(prefix="voicey-apple-rerank-") as temp_dir:
    sample_tsv = Path(temp_dir) / "sample.tsv"
    benchmark.write_batch_sample_tsv(sample_tsv, samples)

    print("[rerank] Qwen baseline …", flush=True)
    qwen_preds = run_qwen_batch(
      binary=args.binary,
      sample_tsv=sample_tsv,
      clips_dir=args.clips_dir,
      model=args.model,
      language=args.language or None,
    )
    qwen_map = {item.audio: item.text for item in qwen_preds}

    apple_app = build_apple_binary(force=args.rebuild_apple)
    print("[rerank] Apple Speech …", flush=True)
    apple_preds = run_apple_batch(
      app_bundle=apple_app,
      sample_tsv=sample_tsv,
      clips_dir=args.clips_dir,
    )
    apple_map = {item.audio: item.text for item in apple_preds}

  oracle_map = oracle_pick(benchmark, samples, qwen_map, apple_map)

  systems = []
  for system_id, mapping in (
    ("qwen-lang-english", qwen_map),
    ("apple-speech", apple_map),
    ("oracle-pick", oracle_map),
  ):
    wer, perfect = aggregate_wer(benchmark, samples, mapping)
    systems.append({"id": system_id, "wer": wer, "perfect": perfect})
    print(f"  {system_id}: WER={wer:.4f} perfect={perfect}/{len(samples)}", flush=True)

  timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
  output_dir = args.output_dir / timestamp
  output_dir.mkdir(parents=True, exist_ok=True)
  payload = {
    "created_at": timestamp,
    "tsv": str(args.tsv),
    "clips_dir": str(args.clips_dir),
    "limit": len(samples),
    "model": args.model,
    "language": args.language,
    "systems": systems,
  }
  summary_json = output_dir / "summary.json"
  summary_json.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
  write_summary_markdown(output_dir / "summary.md", payload)
  print(f"Summary: {summary_json}", flush=True)
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
