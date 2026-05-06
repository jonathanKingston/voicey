#!/usr/bin/env python3
"""Unit tests for the Common Voice benchmark harness."""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).with_name("benchmark_common_voice.py")


def load_benchmark_module():
  spec = importlib.util.spec_from_file_location("benchmark_common_voice", SCRIPT_PATH)
  if spec is None or spec.loader is None:
    raise RuntimeError(f"Unable to load {SCRIPT_PATH}")

  module = importlib.util.module_from_spec(spec)
  sys.modules[spec.name] = module
  spec.loader.exec_module(module)
  return module


benchmark = load_benchmark_module()


class CommonVoiceBenchmarkTests(unittest.TestCase):
  def test_normalize_removes_case_and_punctuation(self) -> None:
    normalized = benchmark.normalize_text(
      "Hello, WORLD! It's ready.",
      case_sensitive=False,
      keep_punctuation=False,
    )

    self.assertEqual(normalized, "hello world its ready")

  def test_compute_text_metrics_counts_word_errors(self) -> None:
    metrics = benchmark.compute_text_metrics(
      reference="hello world",
      prediction="hello there",
      case_sensitive=False,
      keep_punctuation=False,
    )

    self.assertEqual(metrics.reference_words, 2)
    self.assertEqual(metrics.word_errors, 1)
    self.assertEqual(metrics.wer, 0.5)

  def test_voicey_runner_uses_benchmark_transcribe(self) -> None:
    runners = benchmark.voicey_runners(["large-v3_turbo"], Path(".build/debug/Voicey"))

    self.assertEqual(len(runners), 1)
    self.assertEqual(runners[0].name, "large-v3_turbo")
    self.assertIn("benchmark-transcribe", runners[0].command_template)
    self.assertIn("--model large-v3_turbo", runners[0].command_template)
    self.assertIn("{audio}", runners[0].command_template)

  def test_cli_writes_results_for_small_fixture(self) -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
      root = Path(temp_dir)
      clips_dir = root / "clips"
      clips_dir.mkdir()
      (clips_dir / "clip-one.mp3").write_bytes(b"fake")
      (clips_dir / "clip-two.mp3").write_bytes(b"fake")

      tsv_path = root / "test.tsv"
      tsv_path.write_text(
        "\t".join(["client_id", "path", "text"]) + "\n"
        + "\t".join(["speaker-a", "clip-one.mp3", "hello world"]) + "\n"
        + "\t".join(["speaker-b", "clip-two.mp3", "another sentence"]) + "\n",
        encoding="utf-8",
      )

      output_dir = root / "results"
      exit_code = benchmark.main(
        [
          "--tsv",
          str(tsv_path),
          "--clips-dir",
          str(clips_dir),
          "--limit",
          "2",
          "--seed",
          "1",
          "--output-dir",
          str(output_dir),
          "--model-command",
          "echo=python3 -c 'print(\"hello world\")' -- {audio}",
        ]
      )

      self.assertEqual(exit_code, 0)
      summary_paths = list(output_dir.glob("*_summary.json"))
      result_paths = [path for path in output_dir.glob("*.jsonl")]

      self.assertEqual(len(summary_paths), 1)
      self.assertEqual(len(result_paths), 1)

      summary = json.loads(summary_paths[0].read_text(encoding="utf-8"))
      self.assertEqual(summary["summaries"]["echo"]["clips"], 2)
      self.assertGreaterEqual(summary["summaries"]["echo"]["wer"], 0.0)


if __name__ == "__main__":
  unittest.main()
