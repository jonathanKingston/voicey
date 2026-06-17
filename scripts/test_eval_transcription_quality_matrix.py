#!/usr/bin/env python3
"""Unit tests for the transcription quality matrix runner."""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).with_name("eval_transcription_quality_matrix.py")


def load_module():
  spec = importlib.util.spec_from_file_location("eval_transcription_quality_matrix", SCRIPT_PATH)
  if spec is None or spec.loader is None:
    raise RuntimeError(f"Unable to load {SCRIPT_PATH}")
  module = importlib.util.module_from_spec(spec)
  sys.modules[spec.name] = module
  spec.loader.exec_module(module)
  return module


matrix = load_module()


class EvalTranscriptionQualityMatrixTests(unittest.TestCase):
  def test_default_variants_include_core_asr_and_post_process_rows(self) -> None:
    variants = matrix.default_variants(Path("glossary.txt"))
    ids = {variant.id for variant in variants}
    self.assertIn("baseline-1.7b-raw", ids)
    self.assertIn("baseline-1.7b-proc", ids)
    self.assertIn("lang-english-1.7b-raw", ids)
    self.assertIn("repair-glossary-1.7b", ids)
    self.assertIn("itn-1.7b", ids)
    self.assertIn("incremental-1.7b-raw", ids)

  def test_incremental_variant_uses_incremental_batch_command(self) -> None:
    variants = matrix.default_variants(Path("glossary.txt"))
    incremental = next(variant for variant in variants if variant.id == "incremental-1.7b-raw")
    self.assertEqual(incremental.command, "benchmark-transcribe-incremental-batch")

  def test_repair_variant_passes_vocabulary_repair_flag(self) -> None:
    variants = matrix.default_variants(Path("glossary.txt"))
    repair = next(variant for variant in variants if variant.id == "repair-glossary-1.7b")
    self.assertIn("--vocabulary-repair", repair.extra_args)
    self.assertIn("--post-process", repair.extra_args)


if __name__ == "__main__":
  unittest.main()
