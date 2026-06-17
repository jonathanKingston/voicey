#!/usr/bin/env python3
"""Unit tests for read-aloud and LM Studio eval helpers."""

from __future__ import annotations

import importlib.util
import json
import sys
import unittest
from pathlib import Path
from unittest.mock import patch


REPO_ROOT = Path(__file__).resolve().parents[1]


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


readaloud_matrix = load_module(
    "eval_readaloud_quality_matrix",
    REPO_ROOT / "scripts" / "eval_readaloud_quality_matrix.py",
)
lm_studio = load_module(
    "eval_lm_studio_vocabulary",
    REPO_ROOT / "scripts" / "eval_lm_studio_vocabulary.py",
)


class EvalReadAloudQualityMatrixTests(unittest.TestCase):
    def test_aggregate_report_averages_token_recall_by_mode(self) -> None:
        report = {
            "clips": [
                {
                    "modes": {
                        "none": {"reference_token_recall": 0.5, "reference_levenshtein": 0.4},
                        "glossary_artificial": {
                            "reference_token_recall": 1.0,
                            "reference_levenshtein": 0.1,
                            "expect_glossary_token_met": True,
                        },
                    }
                },
                {
                    "modes": {
                        "none": {"reference_token_recall": 0.25, "reference_levenshtein": 0.6},
                        "glossary_artificial": {
                            "reference_token_recall": 0.75,
                            "reference_levenshtein": 0.2,
                            "expect_glossary_token_met": False,
                        },
                    }
                },
            ]
        }
        summary = readaloud_matrix.aggregate_report(report)
        self.assertAlmostEqual(summary["none"]["mean_token_recall"], 0.375)
        self.assertAlmostEqual(summary["glossary_artificial"]["mean_token_recall"], 0.875)
        self.assertEqual(summary["glossary_artificial"]["glossary_misses"], 1)


class EvalLMStudioVocabularyTests(unittest.TestCase):
    def test_score_case_flags_missing_and_forbidden_tokens(self) -> None:
        case = lm_studio.GoldenCase(
            id="demo",
            transcript="hello",
            vocabulary="Voicey",
            must_contain=("Voicey",),
            must_not_contain=("hello",),
        )
        passed = lm_studio.score_case(case, "hello Voicey")
        self.assertFalse(passed["passed"])
        self.assertEqual(passed["missing"], [])
        self.assertEqual(passed["forbidden"], ["hello"])

    @patch.object(lm_studio, "server_available", return_value=False)
    def test_main_skips_when_server_unavailable(self, _mock_available) -> None:
        out = REPO_ROOT / "benchmark-results" / "test-lm-studio-skip.json"
        if out.exists():
            out.unlink()
        exit_code = lm_studio.main(["--out", str(out)])
        self.assertEqual(exit_code, 0)
        payload = json.loads(out.read_text(encoding="utf-8"))
        self.assertTrue(payload["skipped"])


if __name__ == "__main__":
    unittest.main()
