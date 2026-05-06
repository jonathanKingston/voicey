#!/usr/bin/env python3
"""Benchmark ASR commands against a deterministic Common Voice sample."""

from __future__ import annotations

import argparse
import csv
import json
import random
import re
import shlex
import shutil
import subprocess
import sys
import time
import unicodedata
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable, Sequence


DEFAULT_LIMIT = 25
DEFAULT_SEED = 20260506
DEFAULT_TIMEOUT_SECONDS = 120.0
DEFAULT_OUTPUT_DIR = Path("benchmark-results")
TEXT_COLUMNS = ("text", "sentence")
PATH_COLUMN = "path"
MODEL_COMMAND_PLACEHOLDER = "{audio}"


class BenchmarkError(RuntimeError):
  """Raised when the benchmark cannot continue."""


@dataclass(frozen=True)
class Runner:
  name: str
  command_template: str


@dataclass(frozen=True)
class Sample:
  source_row: int
  relative_audio_path: str
  audio_path: Path
  reference: str
  client_id: str | None


@dataclass(frozen=True)
class TextMetrics:
  normalized_reference: str
  normalized_prediction: str
  reference_words: int
  word_errors: int
  wer: float
  reference_chars: int
  char_errors: int
  cer: float


def positive_int(value: str) -> int:
  parsed = int(value)
  if parsed <= 0:
    raise argparse.ArgumentTypeError("must be greater than zero")
  return parsed


def positive_float(value: str) -> float:
  parsed = float(value)
  if parsed <= 0:
    raise argparse.ArgumentTypeError("must be greater than zero")
  return parsed


def parse_model_command(value: str) -> Runner:
  if "=" not in value:
    raise argparse.ArgumentTypeError("expected NAME=COMMAND")

  name, command_template = value.split("=", 1)
  name = name.strip()
  command_template = command_template.strip()

  if not name:
    raise argparse.ArgumentTypeError("model command name cannot be empty")
  if not command_template:
    raise argparse.ArgumentTypeError("model command cannot be empty")
  if MODEL_COMMAND_PLACEHOLDER not in command_template:
    raise argparse.ArgumentTypeError(
      f"model command must include the {MODEL_COMMAND_PLACEHOLDER} placeholder"
    )

  return Runner(name=name, command_template=command_template)


def build_parser() -> argparse.ArgumentParser:
  parser = argparse.ArgumentParser(
    description=(
      "Run one or more ASR commands over a small Common Voice TSV sample and "
      "report WER/CER plus optional real-time factor."
    )
  )
  parser.add_argument(
    "--tsv",
    type=Path,
    required=True,
    help="Common Voice TSV file, usually test.tsv or dev.tsv.",
  )
  parser.add_argument(
    "--clips-dir",
    type=Path,
    required=True,
    help="Directory containing Common Voice audio clips referenced by the TSV.",
  )
  parser.add_argument(
    "--model-command",
    action="append",
    type=parse_model_command,
    required=True,
    metavar="NAME=COMMAND",
    help=(
      "ASR command to benchmark. The command must print the transcript to stdout "
      "and include {audio}, which is replaced with the shell-quoted audio path. "
      "Repeat to compare multiple models."
    ),
  )
  parser.add_argument(
    "--limit",
    type=positive_int,
    default=DEFAULT_LIMIT,
    help=f"Number of clips to sample. Defaults to {DEFAULT_LIMIT}.",
  )
  parser.add_argument(
    "--seed",
    type=int,
    default=DEFAULT_SEED,
    help=f"Deterministic sampling seed. Defaults to {DEFAULT_SEED}.",
  )
  parser.add_argument(
    "--timeout",
    type=positive_float,
    default=DEFAULT_TIMEOUT_SECONDS,
    help=f"Per-clip command timeout in seconds. Defaults to {DEFAULT_TIMEOUT_SECONDS}.",
  )
  parser.add_argument(
    "--output-dir",
    type=Path,
    default=DEFAULT_OUTPUT_DIR,
    help=f"Directory for JSONL results and summary JSON. Defaults to {DEFAULT_OUTPUT_DIR}.",
  )
  parser.add_argument(
    "--suite-name",
    default="common_voice",
    help="Prefix used for output files. Defaults to common_voice.",
  )
  parser.add_argument(
    "--transcript-regex",
    help=(
      "Optional regex applied to stdout to extract the transcript. Use a named "
      "group called 'text' or the first capture group."
    ),
  )
  parser.add_argument(
    "--keep-going",
    action="store_true",
    help="Record command failures and continue. By default the benchmark fails fast.",
  )
  parser.add_argument(
    "--case-sensitive",
    action="store_true",
    help="Keep case when normalizing references and predictions.",
  )
  parser.add_argument(
    "--keep-punctuation",
    action="store_true",
    help="Keep punctuation and symbols when computing WER/CER.",
  )
  parser.add_argument(
    "--skip-missing",
    action="store_true",
    help="Skip sampled rows whose audio file is missing instead of failing.",
  )
  parser.add_argument(
    "--measure-duration",
    action="store_true",
    help="Use ffprobe to measure audio duration and report real-time factor.",
  )
  parser.add_argument(
    "--ffprobe",
    default="ffprobe",
    help="ffprobe executable to use with --measure-duration. Defaults to ffprobe.",
  )
  return parser


def validate_paths(tsv_path: Path, clips_dir: Path) -> None:
  if not tsv_path.is_file():
    raise BenchmarkError(f"TSV file does not exist: {tsv_path}")
  if not clips_dir.is_dir():
    raise BenchmarkError(f"Clips directory does not exist: {clips_dir}")


def resolve_text_column(fieldnames: Sequence[str] | None) -> str:
  if fieldnames is None:
    raise BenchmarkError("TSV file is empty or missing a header row")
  if PATH_COLUMN not in fieldnames:
    raise BenchmarkError(f"TSV file is missing required column: {PATH_COLUMN}")

  for column in TEXT_COLUMNS:
    if column in fieldnames:
      return column

  expected = ", ".join(TEXT_COLUMNS)
  raise BenchmarkError(f"TSV file must contain one of these text columns: {expected}")


def sample_common_voice_rows(
  tsv_path: Path,
  clips_dir: Path,
  limit: int,
  seed: int,
  skip_missing: bool,
) -> tuple[list[Sample], int]:
  rng = random.Random(seed)
  reservoir: list[Sample] = []
  eligible_rows = 0

  with tsv_path.open("r", encoding="utf-8", newline="") as tsv_file:
    reader = csv.DictReader(tsv_file, delimiter="\t")
    text_column = resolve_text_column(reader.fieldnames)

    for source_row, row in enumerate(reader, start=2):
      relative_path = (row.get(PATH_COLUMN) or "").strip()
      reference = (row.get(text_column) or "").strip()

      if not relative_path or not reference:
        continue

      sample = Sample(
        source_row=source_row,
        relative_audio_path=relative_path,
        audio_path=clips_dir / relative_path,
        reference=reference,
        client_id=(row.get("client_id") or "").strip() or None,
      )

      if skip_missing and not sample.audio_path.is_file():
        continue

      eligible_rows += 1
      if len(reservoir) < limit:
        reservoir.append(sample)
        continue

      replacement_index = rng.randrange(eligible_rows)
      if replacement_index < limit:
        reservoir[replacement_index] = sample

  if eligible_rows < limit:
    raise BenchmarkError(
      f"Requested {limit} samples, but only found {eligible_rows} eligible rows"
    )

  samples = sorted(reservoir, key=lambda sample: sample.source_row)
  for sample in samples:
    if not sample.audio_path.is_file():
      raise BenchmarkError(
        f"Sampled audio file does not exist: {sample.audio_path} "
        f"(TSV row {sample.source_row})"
      )

  return samples, eligible_rows


def render_command(runner: Runner, sample: Sample) -> str:
  return (
    runner.command_template.replace(MODEL_COMMAND_PLACEHOLDER, shlex.quote(str(sample.audio_path)))
    .replace("{reference}", shlex.quote(sample.reference))
    .replace("{row}", str(sample.source_row))
  )


def run_transcription_command(
  runner: Runner,
  sample: Sample,
  timeout_seconds: float,
  transcript_regex: str | None,
) -> tuple[str, str, str, float]:
  command = render_command(runner, sample)
  start_time = time.monotonic()

  try:
    completed = subprocess.run(
      command,
      shell=True,
      check=False,
      capture_output=True,
      text=True,
      timeout=timeout_seconds,
    )
  except subprocess.TimeoutExpired as error:
    raise BenchmarkError(
      f"{runner.name} timed out after {timeout_seconds:.1f}s on {sample.relative_audio_path}"
    ) from error

  elapsed_seconds = time.monotonic() - start_time
  stdout = completed.stdout
  stderr = completed.stderr

  if completed.returncode != 0:
    raise BenchmarkError(
      f"{runner.name} exited with status {completed.returncode} on "
      f"{sample.relative_audio_path}\nSTDERR:\n{stderr.strip()}"
    )

  prediction = extract_transcript(stdout, transcript_regex)
  if not prediction:
    raise BenchmarkError(
      f"{runner.name} produced an empty transcript on {sample.relative_audio_path}"
    )

  return prediction, stdout, stderr, elapsed_seconds


def extract_transcript(stdout: str, transcript_regex: str | None) -> str:
  if transcript_regex is None:
    return stdout.strip()

  match = re.search(transcript_regex, stdout, flags=re.MULTILINE)
  if match is None:
    raise BenchmarkError("transcript regex did not match command stdout")

  if "text" in match.groupdict():
    return match.group("text").strip()
  if match.lastindex:
    return match.group(1).strip()
  return match.group(0).strip()


def normalize_text(text: str, case_sensitive: bool, keep_punctuation: bool) -> str:
  normalized = unicodedata.normalize("NFKC", text)
  if not case_sensitive:
    normalized = normalized.casefold()

  if not keep_punctuation:
    characters: list[str] = []
    for character in normalized:
      category = unicodedata.category(character)
      if category.startswith("P"):
        continue
      if category.startswith("S"):
        characters.append(" ")
        continue
      characters.append(character)
    normalized = "".join(characters)

  return " ".join(normalized.split())


def edit_distance(reference: Sequence[Any], prediction: Sequence[Any]) -> int:
  if not reference:
    return len(prediction)
  if not prediction:
    return len(reference)

  previous = list(range(len(prediction) + 1))
  for reference_index, reference_item in enumerate(reference, start=1):
    current = [reference_index]
    for prediction_index, prediction_item in enumerate(prediction, start=1):
      insertion = current[prediction_index - 1] + 1
      deletion = previous[prediction_index] + 1
      substitution = previous[prediction_index - 1] + (
        0 if reference_item == prediction_item else 1
      )
      current.append(min(insertion, deletion, substitution))
    previous = current

  return previous[-1]


def compute_text_metrics(
  reference: str,
  prediction: str,
  case_sensitive: bool,
  keep_punctuation: bool,
) -> TextMetrics:
  normalized_reference = normalize_text(reference, case_sensitive, keep_punctuation)
  normalized_prediction = normalize_text(prediction, case_sensitive, keep_punctuation)

  reference_words = normalized_reference.split()
  prediction_words = normalized_prediction.split()
  word_errors = edit_distance(reference_words, prediction_words)
  wer = safe_error_rate(word_errors, len(reference_words), len(prediction_words))

  reference_chars = list(normalized_reference)
  prediction_chars = list(normalized_prediction)
  char_errors = edit_distance(reference_chars, prediction_chars)
  cer = safe_error_rate(char_errors, len(reference_chars), len(prediction_chars))

  return TextMetrics(
    normalized_reference=normalized_reference,
    normalized_prediction=normalized_prediction,
    reference_words=len(reference_words),
    word_errors=word_errors,
    wer=wer,
    reference_chars=len(reference_chars),
    char_errors=char_errors,
    cer=cer,
  )


def safe_error_rate(errors: int, reference_count: int, prediction_count: int) -> float:
  if reference_count > 0:
    return errors / reference_count
  if prediction_count > 0:
    return 1.0
  return 0.0


def ensure_ffprobe(ffprobe: str) -> None:
  if shutil.which(ffprobe) is None:
    raise BenchmarkError(f"--measure-duration requires ffprobe, but it was not found: {ffprobe}")


def audio_duration_seconds(audio_path: Path, ffprobe: str) -> float:
  completed = subprocess.run(
    [
      ffprobe,
      "-v",
      "error",
      "-show_entries",
      "format=duration",
      "-of",
      "default=noprint_wrappers=1:nokey=1",
      str(audio_path),
    ],
    check=False,
    capture_output=True,
    text=True,
  )

  if completed.returncode != 0:
    raise BenchmarkError(
      f"ffprobe failed for {audio_path}\nSTDERR:\n{completed.stderr.strip()}"
    )

  try:
    duration = float(completed.stdout.strip())
  except ValueError as error:
    raise BenchmarkError(f"ffprobe returned an invalid duration for {audio_path}") from error

  if duration <= 0:
    raise BenchmarkError(f"ffprobe returned a non-positive duration for {audio_path}")

  return duration


def summarize_results(records: Iterable[dict[str, Any]]) -> dict[str, dict[str, Any]]:
  summaries: dict[str, dict[str, Any]] = {}

  for record in records:
    model = record["model"]
    summary = summaries.setdefault(
      model,
      {
        "clips": 0,
        "failures": 0,
        "word_errors": 0,
        "reference_words": 0,
        "char_errors": 0,
        "reference_chars": 0,
        "total_processing_seconds": 0.0,
        "total_audio_seconds": 0.0,
      },
    )

    if "error" in record:
      summary["failures"] += 1
      continue

    summary["clips"] += 1
    summary["word_errors"] += record["word_errors"]
    summary["reference_words"] += record["reference_words"]
    summary["char_errors"] += record["char_errors"]
    summary["reference_chars"] += record["reference_chars"]
    summary["total_processing_seconds"] += record["processing_seconds"]
    if record.get("audio_seconds") is not None:
      summary["total_audio_seconds"] += record["audio_seconds"]

  for summary in summaries.values():
    summary["wer"] = safe_divide(summary["word_errors"], summary["reference_words"])
    summary["cer"] = safe_divide(summary["char_errors"], summary["reference_chars"])
    if summary["total_audio_seconds"] > 0:
      summary["real_time_factor"] = (
        summary["total_processing_seconds"] / summary["total_audio_seconds"]
      )
    else:
      summary["real_time_factor"] = None

  return summaries


def safe_divide(numerator: float, denominator: float) -> float | None:
  if denominator == 0:
    return None
  return numerator / denominator


def write_json(path: Path, payload: dict[str, Any]) -> None:
  path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def print_summary(summaries: dict[str, dict[str, Any]]) -> None:
  print("")
  print("Common Voice benchmark summary")
  print("model\tclips\tfailures\tWER\tCER\tRTF")
  for model, summary in sorted(summaries.items()):
    wer = format_optional_rate(summary["wer"])
    cer = format_optional_rate(summary["cer"])
    rtf = format_optional_rate(summary["real_time_factor"])
    print(f"{model}\t{summary['clips']}\t{summary['failures']}\t{wer}\t{cer}\t{rtf}")


def format_optional_rate(value: float | None) -> str:
  if value is None:
    return "-"
  return f"{value:.4f}"


def benchmark(args: argparse.Namespace) -> int:
  runners: list[Runner] = args.model_command
  runner_names = [runner.name for runner in runners]
  if len(set(runner_names)) != len(runner_names):
    raise BenchmarkError("model command names must be unique")

  validate_paths(args.tsv, args.clips_dir)
  if args.measure_duration:
    ensure_ffprobe(args.ffprobe)

  samples, eligible_rows = sample_common_voice_rows(
    tsv_path=args.tsv,
    clips_dir=args.clips_dir,
    limit=args.limit,
    seed=args.seed,
    skip_missing=args.skip_missing,
  )

  args.output_dir.mkdir(parents=True, exist_ok=True)
  timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
  results_path = args.output_dir / f"{args.suite_name}_{timestamp}.jsonl"
  summary_path = args.output_dir / f"{args.suite_name}_{timestamp}_summary.json"

  print(
    f"Benchmarking {len(runners)} model command(s) on {len(samples)} of "
    f"{eligible_rows} eligible Common Voice rows"
  )
  print(f"Results: {results_path}")

  records: list[dict[str, Any]] = []
  with results_path.open("w", encoding="utf-8") as results_file:
    for sample_index, sample in enumerate(samples, start=1):
      audio_seconds = (
        audio_duration_seconds(sample.audio_path, args.ffprobe) if args.measure_duration else None
      )

      for runner in runners:
        print(
          f"[{sample_index}/{len(samples)}] {runner.name}: {sample.relative_audio_path}",
          flush=True,
        )
        try:
          prediction, stdout, stderr, processing_seconds = run_transcription_command(
            runner=runner,
            sample=sample,
            timeout_seconds=args.timeout,
            transcript_regex=args.transcript_regex,
          )
          metrics = compute_text_metrics(
            reference=sample.reference,
            prediction=prediction,
            case_sensitive=args.case_sensitive,
            keep_punctuation=args.keep_punctuation,
          )
          record = {
            "model": runner.name,
            "source_row": sample.source_row,
            "client_id": sample.client_id,
            "audio": sample.relative_audio_path,
            "reference": sample.reference,
            "prediction": prediction,
            "normalized_reference": metrics.normalized_reference,
            "normalized_prediction": metrics.normalized_prediction,
            "reference_words": metrics.reference_words,
            "word_errors": metrics.word_errors,
            "wer": metrics.wer,
            "reference_chars": metrics.reference_chars,
            "char_errors": metrics.char_errors,
            "cer": metrics.cer,
            "processing_seconds": processing_seconds,
            "audio_seconds": audio_seconds,
            "real_time_factor": (
              processing_seconds / audio_seconds if audio_seconds is not None else None
            ),
            "stdout": stdout,
            "stderr": stderr,
          }
        except BenchmarkError as error:
          if not args.keep_going:
            raise
          record = {
            "model": runner.name,
            "source_row": sample.source_row,
            "client_id": sample.client_id,
            "audio": sample.relative_audio_path,
            "reference": sample.reference,
            "error": str(error),
          }

        records.append(record)
        results_file.write(json.dumps(record, sort_keys=True) + "\n")
        results_file.flush()

  summaries = summarize_results(records)
  write_json(
    summary_path,
    {
      "created_at": timestamp,
      "tsv": str(args.tsv),
      "clips_dir": str(args.clips_dir),
      "limit": args.limit,
      "seed": args.seed,
      "models": runner_names,
      "results_path": str(results_path),
      "summaries": summaries,
    },
  )
  print_summary(summaries)
  print(f"Summary: {summary_path}")

  return 0


def main(argv: Sequence[str] | None = None) -> int:
  parser = build_parser()
  args = parser.parse_args(argv)
  try:
    return benchmark(args)
  except BenchmarkError as error:
    print(f"error: {error}", file=sys.stderr)
    return 1


if __name__ == "__main__":
  raise SystemExit(main())
