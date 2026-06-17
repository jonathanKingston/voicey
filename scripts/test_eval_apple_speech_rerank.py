#!/usr/bin/env python3
"""Unit tests for Apple Speech rerank eval."""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "scripts/eval_apple_speech_rerank.py"


def load_module():
  spec = importlib.util.spec_from_file_location("eval_apple_speech_rerank", SCRIPT)
  if spec is None or spec.loader is None:
    raise RuntimeError(f"Unable to load {SCRIPT}")
  module = importlib.util.module_from_spec(spec)
  sys.modules[spec.name] = module
  spec.loader.exec_module(module)
  return module


eval_rerank = load_module()
benchmark = eval_rerank.load_benchmark_module()


class OraclePickTests(unittest.TestCase):
  def test_oracle_picks_lower_wer_hypothesis(self) -> None:
    class Sample:
      relative_audio_path = "a.wav"
      reference = "I'm heading out now."

    qwen = {"a.wav": "I am heading out."}
    apple = {"a.wav": "I'm heading out now."}
    picked = eval_rerank.oracle_pick(benchmark, [Sample()], qwen, apple)
    self.assertEqual(picked["a.wav"], apple["a.wav"])


if __name__ == "__main__":
  unittest.main()
