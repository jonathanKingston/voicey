#!/usr/bin/env python3
"""Prepare a deterministic LibriSpeech sample for the Common Voice benchmark harness."""

from __future__ import annotations

import argparse
import csv
import json
import random
import subprocess
import sys
import tarfile
from pathlib import Path, PurePosixPath


DEFAULT_ARCHIVE = Path("benchmark-data/downloads/dev-clean.tar.gz")
DEFAULT_PREPARED_ROOT = Path("benchmark-data/common-voice/prepared/librispeech_clean")
DEFAULT_LIMIT = 200
DEFAULT_SEED = 20260506
DEFAULT_SPLIT = "test"


class PrepareError(RuntimeError):
  pass


def positive_int(value: str) -> int:
  parsed = int(value)
  if parsed <= 0:
    raise argparse.ArgumentTypeError("must be greater than zero")
  return parsed


def build_parser() -> argparse.ArgumentParser:
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument("--archive", type=Path, default=DEFAULT_ARCHIVE)
  parser.add_argument("--prepared-root", type=Path, default=DEFAULT_PREPARED_ROOT)
  parser.add_argument("--split", default=DEFAULT_SPLIT)
  parser.add_argument("--limit", type=positive_int, default=DEFAULT_LIMIT)
  parser.add_argument("--seed", type=int, default=DEFAULT_SEED)
  parser.add_argument("--overwrite", action="store_true")
  return parser


def parse_transcript(text: str) -> dict[str, str]:
  transcripts: dict[str, str] = {}
  for line in text.splitlines():
    line = line.strip()
    if not line:
      continue
    utterance_id, _, transcript = line.partition(" ")
    if utterance_id and transcript:
      transcripts[utterance_id] = transcript.upper()
  return transcripts


def reservoir_sample(items: list[tuple[str, str, str]], limit: int, seed: int) -> list[tuple[str, str, str]]:
  rng = random.Random(seed)
  reservoir: list[tuple[str, str, str]] = []
  for index, item in enumerate(items, start=1):
    if len(reservoir) < limit:
      reservoir.append(item)
      continue
    replacement_index = rng.randrange(index)
    if replacement_index < limit:
      reservoir[replacement_index] = item
  return reservoir


def convert_to_wav(source_flac: Path, destination_wav: Path) -> None:
  destination_wav.parent.mkdir(parents=True, exist_ok=True)
  command = [
    "ffmpeg",
    "-nostdin",
    "-hide_banner",
    "-loglevel",
    "error",
    "-y",
    "-i",
    str(source_flac),
    "-ac",
    "1",
    "-ar",
    "16000",
    str(destination_wav),
  ]
  subprocess.run(command, check=True)


def prepare(args: argparse.Namespace) -> Path:
  if not args.archive.is_file():
    raise PrepareError(f"Missing archive: {args.archive}")

  prepared_dir = (
    args.prepared_root / f"{args.split}-limit{args.limit}-seed{args.seed}"
  )
  tsv_path = prepared_dir / f"{args.split}.tsv"
  clips_dir = prepared_dir / "clips"
  manifest_path = prepared_dir / "manifest.json"

  if manifest_path.is_file() and tsv_path.is_file() and clips_dir.is_dir() and not args.overwrite:
    return prepared_dir

  if prepared_dir.exists() and args.overwrite:
    for child in sorted(prepared_dir.rglob("*"), reverse=True):
      if child.is_file() or child.is_symlink():
        child.unlink()
      elif child.is_dir():
        child.rmdir()
    prepared_dir.rmdir()

  prepared_dir.mkdir(parents=True, exist_ok=True)
  clips_dir.mkdir(parents=True, exist_ok=True)

  utterances: list[tuple[str, str, str]] = []
  with tarfile.open(args.archive, mode="r:*") as archive:
    transcript_members = {
      PurePosixPath(member.name).name: member
      for member in archive.getmembers()
      if member.isfile() and member.name.endswith(".trans.txt")
    }
    for transcript_name, transcript_member in sorted(transcript_members.items()):
      extracted = archive.extractfile(transcript_member)
      if extracted is None:
        continue
      transcript_text = extracted.read().decode("utf-8")
      transcripts = parse_transcript(transcript_text)
      transcript_dir = PurePosixPath(transcript_member.name).parent
      speaker_id = transcript_name.split("-", maxsplit=1)[0]
      for utterance_id, text in transcripts.items():
        flac_member_name = str(transcript_dir / f"{utterance_id}.flac")
        utterances.append((flac_member_name, speaker_id, text))

    if len(utterances) < args.limit:
      raise PrepareError(
        f"Requested {args.limit} samples, but archive only has {len(utterances)} utterances"
      )

    sampled = reservoir_sample(utterances, args.limit, args.seed)
    rows: list[dict[str, str]] = []
    for index, (flac_member_name, speaker_id, text) in enumerate(sampled, start=1):
      clip_name = f"clip_{index:05d}.wav"
      flac_member = archive.getmember(flac_member_name)
      extracted = archive.extractfile(flac_member)
      if extracted is None:
        raise PrepareError(f"Unable to extract {flac_member_name}")

      temp_flac = prepared_dir / f"_tmp_{index}.flac"
      with temp_flac.open("wb") as output_file:
        output_file.write(extracted.read())
      convert_to_wav(temp_flac, clips_dir / clip_name)
      temp_flac.unlink()
      rows.append({"client_id": speaker_id, "path": clip_name, "text": text})
      if index % 25 == 0 or index == args.limit:
        print(f"Prepared {index}/{args.limit}: {clip_name}")

  with tsv_path.open("w", encoding="utf-8", newline="") as tsv_file:
    writer = csv.DictWriter(tsv_file, fieldnames=["client_id", "path", "text"], delimiter="\t")
    writer.writeheader()
    writer.writerows(rows)

  manifest_path.write_text(
    json.dumps(
      {
        "source": "librispeech-dev-clean",
        "archive_path": str(args.archive),
        "split": args.split,
        "limit": args.limit,
        "seed": args.seed,
        "prepared_dir": str(prepared_dir),
        "tsv_path": str(tsv_path),
        "clips_dir": str(clips_dir),
        "note": (
          "LibriSpeech dev-clean stand-in for Common Voice when MDC_API_KEY is unavailable."
        ),
      },
      indent=2,
      sort_keys=True,
    )
    + "\n",
    encoding="utf-8",
  )
  return prepared_dir


def main(argv: list[str] | None = None) -> int:
  parser = build_parser()
  args = parser.parse_args(argv)
  try:
    prepared_dir = prepare(args)
  except (PrepareError, subprocess.CalledProcessError) as error:
    print(f"error: {error}", file=sys.stderr)
    return 1

  print(f"Prepared: {prepared_dir}")
  print(f"TSV: {prepared_dir / f'{args.split}.tsv'}")
  print(f"Clips: {prepared_dir / 'clips'}")
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
