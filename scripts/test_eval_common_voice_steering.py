#!/usr/bin/env python3
"""Unit tests for Common Voice steering eval helpers."""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path


def load_eval_module():
    path = Path(__file__).with_name("eval_common_voice_steering.py")
    spec = importlib.util.spec_from_file_location("eval_common_voice_steering", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"unable to load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


eval_cv = load_eval_module()


class EvalCommonVoiceSteeringTests(unittest.TestCase):
    def test_oracle_glossary_skips_stopwords_and_short_words(self) -> None:
        gloss = eval_cv.oracle_glossary_from_reference(
            "The quick brown fox jumps over the lazy dog."
        )
        self.assertNotIn("the", gloss.lower())
        self.assertIn("quick", gloss.lower())
        self.assertIn("brown", gloss.lower())

    def test_missed_token_glossary_from_baseline(self) -> None:
        ref = "Ship the pull request when CI is green."
        pred = "Ship the pull request when see eye is green."
        gloss = eval_cv.missed_token_glossary(ref, pred)
        self.assertIsNotNone(gloss)
        assert gloss is not None
        self.assertIn("ci", gloss.lower())

    def test_missed_token_glossary_none_when_exact(self) -> None:
        ref = "Hello world"
        self.assertIsNone(eval_cv.missed_token_glossary(ref, ref))

    def test_default_prepared_dir_matches_prepare_module(self) -> None:
        prepare = eval_cv.load_prepare_module()
        expected = prepare.prepared_directory(
            eval_cv.DEFAULT_PREPARED_ROOT,
            eval_cv.DEFAULT_DATASET_ID,
            eval_cv.DEFAULT_SPLIT,
            eval_cv.DEFAULT_LIMIT,
            eval_cv.DEFAULT_SEED,
        )
        actual = eval_cv.default_prepared_dir()
        self.assertEqual(actual, expected)


if __name__ == "__main__":
    unittest.main()
