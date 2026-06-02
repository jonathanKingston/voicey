#!/usr/bin/env python3
"""Unit tests for steering cap sweep scoring (no workers, no user data)."""

import unittest

from sweep_steering_caps import (
    CapConfig,
    cap_grid,
    normalized_levenshtein,
    steering_overlap_fraction,
    summarize_clip,
)


class SteeringCapSweepTests(unittest.TestCase):
    def test_levenshtein_identical(self) -> None:
        self.assertEqual(normalized_levenshtein("hello world", "hello world"), 0.0)

    def test_levenshtein_empty(self) -> None:
        self.assertEqual(normalized_levenshtein("", "hi"), 1.0)

    def test_overlap_fraction(self) -> None:
        overlap = steering_overlap_fraction(
            "Voicey Benchmarks merge history",
            ["Voicey", "Benchmarks", "merge"],
        )
        self.assertGreater(overlap, 0.5)

    def test_cap_grid_skips_invalid_screen_budget(self) -> None:
        configs = cap_grid((32,), (16,), (512,))
        self.assertEqual(configs, [])

    def test_summarize_prefers_low_overlap_and_small_context(self) -> None:
        rows = [
            {
                "config": CapConfig(16, 48, 512).__dict__,
                "baseline_distance": 0.4,
                "steering_overlap": 0.6,
                "context_chars": 512,
                "term_count": 12,
            },
            {
                "config": CapConfig(8, 32, 256).__dict__,
                "baseline_distance": 0.05,
                "steering_overlap": 0.1,
                "context_chars": 256,
                "term_count": 8,
            },
        ]
        summary = summarize_clip(rows, eval_profile=None)
        assert summary is not None
        self.assertEqual(summary["recommended"]["max_screen_terms"], 8)


if __name__ == "__main__":
    unittest.main()
