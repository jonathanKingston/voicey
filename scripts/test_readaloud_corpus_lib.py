#!/usr/bin/env python3
"""Tests for readaloud_corpus_lib."""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path


def load_lib():
    path = Path(__file__).with_name("readaloud_corpus_lib.py")
    spec = importlib.util.spec_from_file_location("readaloud_corpus_lib", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


lib = load_lib()


class ReadAloudCorpusLibTests(unittest.TestCase):
    def test_manifest_loads_and_has_glossary(self) -> None:
        manifest = lib.load_corpus_manifest()
        glossary = lib.blended_glossary(manifest)
        self.assertIn("Klorp-9-alpha", glossary)
        self.assertIn("IncrementalTranscriptionCoordinator.swift", glossary)

    def test_clips_with_id_prefix(self) -> None:
        clips = lib.clips_from_manifest(require_id=True)
        self.assertGreaterEqual(len(clips), 27)
        self.assertTrue(all(c.id_prefix for c in clips))

    def test_all_v3_lines_have_id_prefix(self) -> None:
        manifest = lib.load_corpus_manifest()
        clips = manifest["clips"]
        self.assertEqual(len(clips), 27)
        self.assertTrue(all(row.get("id_prefix") for row in clips))
        self.assertEqual(len(lib.pending_clips()), 0)


if __name__ == "__main__":
    unittest.main()
