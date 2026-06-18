"""Convert benchmark audio clips to 16 kHz mono PCM WAV (Common Voice MP3, LibriSpeech FLAC)."""

from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path


class BenchmarkWavConvertError(RuntimeError):
  pass


def _afconvert_bin() -> str | None:
  found = shutil.which("afconvert")
  if found:
    return found
  macos_default = Path("/usr/bin/afconvert")
  if sys.platform == "darwin" and macos_default.is_file():
    return str(macos_default)
  return None


def convert_to_16k_mono_wav(source: Path, dest: Path) -> None:
  dest.parent.mkdir(parents=True, exist_ok=True)
  afconvert = _afconvert_bin()
  if afconvert:
    completed = subprocess.run(
      [
        afconvert,
        "-f",
        "WAVE",
        "-d",
        "LEI16@16000",
        "-c",
        "1",
        str(source),
        str(dest),
      ],
      capture_output=True,
      text=True,
      check=False,
    )
    if completed.returncode == 0 and dest.is_file():
      return
  ffmpeg = shutil.which("ffmpeg")
  if not ffmpeg:
    hint = (
      "Install ffmpeg (e.g. brew install ffmpeg). "
      "macOS afconvert cannot decode some formats (Common Voice MP3)."
    )
    raise BenchmarkWavConvertError(hint)
  completed = subprocess.run(
    [
      ffmpeg,
      "-nostdin",
      "-hide_banner",
      "-loglevel",
      "error",
      "-y",
      "-i",
      str(source),
      "-ar",
      "16000",
      "-ac",
      "1",
      "-c:a",
      "pcm_s16le",
      str(dest),
    ],
    capture_output=True,
    text=True,
    check=False,
  )
  if completed.returncode != 0:
    raise BenchmarkWavConvertError(
      f"ffmpeg failed for {source}:\n{completed.stderr.strip()}"
    )
