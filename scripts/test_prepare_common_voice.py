#!/usr/bin/env python3
"""Unit tests for Common Voice preparation."""

from __future__ import annotations

import importlib.util
import json
import contextlib
import io
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).with_name("prepare_common_voice.py")


def load_prepare_module():
  spec = importlib.util.spec_from_file_location("prepare_common_voice", SCRIPT_PATH)
  if spec is None or spec.loader is None:
    raise RuntimeError(f"Unable to load {SCRIPT_PATH}")

  module = importlib.util.module_from_spec(spec)
  sys.modules[spec.name] = module
  spec.loader.exec_module(module)
  return module


prepare = load_prepare_module()


class PrepareCommonVoiceTests(unittest.TestCase):
  def test_known_large_dataset_fails_without_explicit_allow(self) -> None:
    with self.assertRaises(prepare.CommonVoicePrepareError):
      prepare.guard_known_dataset_size(
        "cmndapwry02jnmh07dyo46mot",
        max_archive_gb=2.0,
        allow_large_download=False,
      )

  def test_extracts_deterministic_sample_from_archive(self) -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
      root = Path(temp_dir)
      source_dir = root / "source" / "cv-corpus"
      clips_dir = source_dir / "clips"
      clips_dir.mkdir(parents=True)
      (clips_dir / "clip-one.mp3").write_bytes(b"one")
      (clips_dir / "clip-two.mp3").write_bytes(b"two")

      (source_dir / "test.tsv").write_text(
        "\t".join(["client_id", "path", "text"]) + "\n"
        + "\t".join(["speaker-a", "clip-one.mp3", "hello world"]) + "\n"
        + "\t".join(["speaker-b", "clip-two.mp3", "another sentence"]) + "\n",
        encoding="utf-8",
      )

      archive_path = root / "common-voice.tar.gz"
      with tarfile.open(archive_path, "w:gz") as archive:
        archive.add(source_dir, arcname="cv-corpus")

      with contextlib.redirect_stdout(io.StringIO()):
        exit_code = prepare.main(
          [
            "--source",
            "archive",
            "--archive",
            str(archive_path),
            "--dataset-id",
            "fixture",
            "--prepared-root",
            str(root / "prepared"),
            "--limit",
            "2",
            "--seed",
            "1",
            "--json",
          ]
        )

      self.assertEqual(exit_code, 0)
      manifest_path = root / "prepared" / "fixture" / "test-limit2-seed1" / "manifest.json"
      manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
      prepared_dir = Path(manifest["prepared_dir"])

      self.assertTrue((prepared_dir / "test.tsv").is_file())
      self.assertEqual((prepared_dir / "clips" / "clip-one.mp3").read_bytes(), b"one")
      self.assertEqual((prepared_dir / "clips" / "clip-two.mp3").read_bytes(), b"two")

  def test_extracts_csv_archive_with_extensionless_ipfs_audio_files(self) -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
      root = Path(temp_dir)
      source_dir = root / "effect-ai"
      audio_dir = source_dir / "audio"
      audio_dir.mkdir(parents=True)
      cid = "QmWU8tiurj4SS1eUFkX14g69wancWE9kC4sW8vxQUfieWi"
      (audio_dir / f"{cid}.mp3").write_bytes(b"audio")

      (source_dir / "effectai_sentence_recording_dataset.csv").write_text(
        "sentence,sentence_length,author_id,audio_file,duration_sec\n"
        f"I'm heading out now.,4,4061,{cid},0.91\n",
        encoding="utf-8",
      )

      archive_path = root / "effect-ai.tar.gz"
      with tarfile.open(archive_path, "w:gz") as archive:
        archive.add(source_dir, arcname=".")

      with contextlib.redirect_stdout(io.StringIO()):
        exit_code = prepare.main(
          [
            "--source",
            "archive",
            "--archive",
            str(archive_path),
            "--dataset-id",
            "cmkfm9fbl00nto0070sdcrak2",
            "--prepared-root",
            str(root / "prepared"),
            "--limit",
            "1",
            "--seed",
            "1",
          ]
        )

      self.assertEqual(exit_code, 0)
      prepared_dir = root / "prepared" / "cmkfm9fbl00nto0070sdcrak2" / "test-limit1-seed1"
      self.assertEqual((prepared_dir / "clips" / f"{cid}.mp3").read_bytes(), b"audio")


if __name__ == "__main__":
  unittest.main()
