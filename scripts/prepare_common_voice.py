#!/usr/bin/env python3
"""Prepare a small deterministic Common Voice benchmark sample."""

from __future__ import annotations

import argparse
import codecs
import csv
import importlib.util
import io
import json
import os
import random
import shutil
import subprocess
import sys
import tarfile
import tempfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Sequence


DEFAULT_DATASET_ID = "cmkfm9fbl00nto0070sdcrak2"
DEFAULT_SOURCE = "mdc"
DEFAULT_HF_DATASET = "mozilla-foundation/common_voice_13_0"
DEFAULT_HF_CONFIG = "en"
DEFAULT_DOWNLOAD_DIR = Path("benchmark-data/common-voice/downloads")
DEFAULT_PREPARED_ROOT = Path("benchmark-data/common-voice/prepared")
DEFAULT_LIMIT = 25
DEFAULT_SEED = 20260506
DEFAULT_SPLIT = "test"
DEFAULT_SAMPLE_STRATEGY = "first"
DEFAULT_MAX_ARCHIVE_GB = 2.0
DEFAULT_MAX_STREAM_GB = 10.0
DEFAULT_HF_SHUFFLE_BUFFER = 250
LOCAL_ENV_FILES = (".env.production", ".env.local", ".env")
MDC_DATASET_PAGE = "https://datacollective.mozillafoundation.org/datasets"
TEXT_COLUMNS = ("text", "sentence", "transcription", "reference")
PATH_COLUMNS = ("path", "audio_file", "audio")
CANONICAL_PATH_COLUMN = "path"
CANONICAL_TEXT_COLUMN = "text"
KNOWN_DATASETS = {
  # Pulled from MDC (2026-06): spontaneous English alpha ID no longer exists.
  "cmn1pv5hi00uto1072y1074y7": {
    "name": "Common Voice Spontaneous Speech 3.0 - English (deprecated on MDC)",
    "size_gb": 0.449,
  },
  "cmkfm9fbl00nto0070sdcrak2": {
    "name": "Effect AI Scripted Speech 1.0 - English (recommended default)",
    "size_gb": 0.66,
  },
  "cmko7havo02f5nw07rbwwhowe": {
    "name": "Common Voice v24 English en-AU subset",
    "size_gb": 1.92,
  },
  "cmn2cxzy701iumm077t5ayw0e": {
    "name": "Common Voice Scripted Speech 25.0 - Hindi",
    "size_gb": 0.532,
  },
  "cmndapwry02jnmh07dyo46mot": {
    "name": "Common Voice Scripted Speech 25.0 - English (often restricted on MDC)",
    "size_gb": 87.84,
  },
}


class CommonVoicePrepareError(RuntimeError):
  """Raised when Common Voice preparation cannot continue."""


def load_local_env_files(repo_root: Path | None = None) -> None:
  """Load untracked env files so MDC/HF tokens work without exporting in the shell."""
  root = repo_root or Path(__file__).resolve().parents[1]
  for name in LOCAL_ENV_FILES:
    path = root / name
    if not path.is_file():
      continue
    for line in path.read_text(encoding="utf-8").splitlines():
      stripped = line.strip()
      if not stripped or stripped.startswith("#") or "=" not in stripped:
        continue
      key, _, value = stripped.partition("=")
      key = key.strip()
      if not key:
        continue
      value = value.strip().strip('"').strip("'")
      os.environ.setdefault(key, value)


def mdc_dataset_url(dataset_id: str) -> str:
  return f"{MDC_DATASET_PAGE}/{dataset_id}"


def mdc_access_error_message(dataset_id: str) -> str:
  known = KNOWN_DATASETS.get(dataset_id, {})
  note = ""
  if "restricted" in str(known.get("name", "")).lower() or "deprecated" in str(known.get("name", "")).lower():
    note = " This dataset may no longer be publicly downloadable on MDC."
  return (
    f"MDC denied dataset access for {dataset_id}.{note} "
    f"Log in at {MDC_DATASET_PAGE}, open {mdc_dataset_url(dataset_id)}, "
    "accept the dataset terms (same account as MDC_API_KEY), then retry. "
    "See Benchmarks/CommonVoice.md for working English alternatives."
  )


@dataclass(frozen=True)
class PreparedCommonVoiceDataset:
  archive_path: Path
  prepared_dir: Path
  tsv_path: Path
  clips_dir: Path
  manifest_path: Path


def positive_int(value: str) -> int:
  parsed = int(value)
  if parsed <= 0:
    raise argparse.ArgumentTypeError("must be greater than zero")
  return parsed


def build_parser() -> argparse.ArgumentParser:
  parser = argparse.ArgumentParser(
    description=(
      "Prepare a small Common Voice benchmark sample from a streaming English "
      "source or from a Mozilla Data Collective archive."
    )
  )
  parser.add_argument(
    "--source",
    choices=("mdc-stream", "hf-stream", "mdc", "archive"),
    default=DEFAULT_SOURCE,
    help=(
      "Sample source. `mdc` downloads a full MDC archive; `mdc-stream` streams "
      "an MDC archive and stops after the sampled clips; `hf-stream` uses a "
      "Hugging Face subset; `archive` samples an existing local archive. "
      f"Defaults to {DEFAULT_SOURCE}."
    ),
  )
  parser.add_argument(
    "--dataset-id",
    default=DEFAULT_DATASET_ID,
    help=(
      "MDC dataset ID for MDC sources. Defaults to English Common Voice "
      f"Spontaneous Speech 3.0 ({DEFAULT_DATASET_ID})."
    ),
  )
  parser.add_argument(
    "--hf-dataset",
    default=DEFAULT_HF_DATASET,
    help=f"Hugging Face dataset for --source hf-stream. Defaults to {DEFAULT_HF_DATASET}.",
  )
  parser.add_argument(
    "--hf-config",
    default=DEFAULT_HF_CONFIG,
    help=f"Hugging Face config/language for --source hf-stream. Defaults to {DEFAULT_HF_CONFIG}.",
  )
  parser.add_argument(
    "--archive",
    type=Path,
    help="Use an existing .tar/.tar.gz archive with --source archive.",
  )
  parser.add_argument(
    "--download-dir",
    type=Path,
    default=DEFAULT_DOWNLOAD_DIR,
    help=f"Directory for MDC archive downloads. Defaults to {DEFAULT_DOWNLOAD_DIR}.",
  )
  parser.add_argument(
    "--prepared-root",
    type=Path,
    default=DEFAULT_PREPARED_ROOT,
    help=f"Directory for extracted benchmark samples. Defaults to {DEFAULT_PREPARED_ROOT}.",
  )
  parser.add_argument(
    "--split",
    default=DEFAULT_SPLIT,
    choices=("train", "dev", "test", "validated"),
    help=f"Common Voice split to sample. Defaults to {DEFAULT_SPLIT}.",
  )
  parser.add_argument(
    "--limit",
    type=positive_int,
    default=DEFAULT_LIMIT,
    help=f"Number of clips to extract. Defaults to {DEFAULT_LIMIT}.",
  )
  parser.add_argument(
    "--seed",
    type=int,
    default=DEFAULT_SEED,
    help=f"Deterministic sampling seed. Defaults to {DEFAULT_SEED}.",
  )
  parser.add_argument(
    "--sample-strategy",
    choices=("first", "reservoir"),
    default=DEFAULT_SAMPLE_STRATEGY,
    help=(
      "How to choose rows from the split. `first` is stream-friendly; "
      f"`reservoir` samples across the whole split. Defaults to {DEFAULT_SAMPLE_STRATEGY}."
    ),
  )
  parser.add_argument(
    "--overwrite-sample",
    action="store_true",
    help="Recreate the prepared sampled split even if it already exists.",
  )
  parser.add_argument(
    "--install-sdk",
    action="store_true",
    help="Install missing Python SDKs with pip.",
  )
  parser.add_argument(
    "--hf-shuffle-buffer",
    type=positive_int,
    default=DEFAULT_HF_SHUFFLE_BUFFER,
    help=(
      "Streaming shuffle buffer for --source hf-stream. Larger values improve "
      f"sampling diversity but download more metadata/audio. Defaults to {DEFAULT_HF_SHUFFLE_BUFFER}."
    ),
  )
  parser.add_argument(
    "--max-archive-gb",
    type=float,
    default=DEFAULT_MAX_ARCHIVE_GB,
    help=(
      "Fail before download when a known dataset exceeds this size. "
      f"Defaults to {DEFAULT_MAX_ARCHIVE_GB} GB."
    ),
  )
  parser.add_argument(
    "--max-stream-gb",
    type=float,
    default=DEFAULT_MAX_STREAM_GB,
    help=(
      "Stop an MDC streaming sample after reading this many compressed GB. "
      f"Defaults to {DEFAULT_MAX_STREAM_GB} GB."
    ),
  )
  parser.add_argument(
    "--allow-large-download",
    action="store_true",
    help="Allow known datasets larger than --max-archive-gb.",
  )
  parser.add_argument(
    "--json",
    action="store_true",
    help="Print the prepared dataset manifest JSON to stdout.",
  )
  return parser


def ensure_datacollective_sdk(install_sdk: bool) -> None:
  if importlib.util.find_spec("datacollective") is not None:
    return

  if not install_sdk:
    raise CommonVoicePrepareError(
      "Missing Python package 'datacollective'. Install it with "
      "`python3 -m pip install datacollective` or rerun with --install-sdk."
    )

  completed = subprocess.run(
    [sys.executable, "-m", "pip", "install", "--user", "datacollective"],
    check=False,
    text=True,
  )
  if completed.returncode != 0:
    raise CommonVoicePrepareError("Failed to install datacollective Python SDK")


def ensure_huggingface_streaming_dependencies(install_sdk: bool) -> None:
  missing = [
    package_name
    for module_name, package_name in (("datasets", "datasets"), ("soundfile", "soundfile"))
    if importlib.util.find_spec(module_name) is None
  ]
  if not missing:
    return

  if not install_sdk:
    packages = " ".join(missing)
    raise CommonVoicePrepareError(
      f"Missing Python package(s): {packages}. Install with "
      f"`python3 -m pip install {packages}` or rerun with --install-sdk."
    )

  completed = subprocess.run(
    [sys.executable, "-m", "pip", "install", "--user", *missing],
    check=False,
    text=True,
  )
  if completed.returncode != 0:
    raise CommonVoicePrepareError("Failed to install Hugging Face streaming dependencies")


def guard_known_dataset_size(
  dataset_id: str,
  max_archive_gb: float,
  allow_large_download: bool,
) -> None:
  dataset = KNOWN_DATASETS.get(dataset_id)
  if dataset is None or allow_large_download:
    return

  size_gb = float(dataset["size_gb"])
  if size_gb <= max_archive_gb:
    return

  raise CommonVoicePrepareError(
    f"{dataset['name']} is {size_gb:.2f} GB, which exceeds the "
    f"{max_archive_gb:.2f} GB limit. Use a smaller dataset or pass "
    "--allow-large-download to download it anyway."
  )


def download_dataset_archive(
  dataset_id: str,
  download_dir: Path,
  install_sdk: bool,
  max_archive_gb: float,
  allow_large_download: bool,
) -> Path:
  guard_known_dataset_size(dataset_id, max_archive_gb, allow_large_download)
  ensure_datacollective_sdk(install_sdk)
  from datacollective import download_dataset  # type: ignore

  download_dir.mkdir(parents=True, exist_ok=True)
  try:
    archive_path = download_dataset(
      dataset_id,
      download_directory=str(download_dir),
      show_progress=True,
      overwrite_existing=False,
      enable_logging=True,
    )
  except PermissionError as error:
    raise CommonVoicePrepareError(mdc_access_error_message(dataset_id)) from error
  except Exception as error:
    raise CommonVoicePrepareError(f"MDC dataset download failed: {error}") from error
  return Path(archive_path)


def mdc_download_plan(dataset_id: str, download_dir: Path, install_sdk: bool):
  ensure_datacollective_sdk(install_sdk)
  from datacollective.download import DOWNLOAD_SOURCE_SAVE, _get_download_plan  # type: ignore

  try:
    return _get_download_plan(
      dataset_id,
      str(download_dir),
      download_source=DOWNLOAD_SOURCE_SAVE,
    )
  except PermissionError as error:
    raise CommonVoicePrepareError(mdc_access_error_message(dataset_id)) from error
  except Exception as error:
    raise CommonVoicePrepareError(f"Unable to create MDC download session: {error}") from error


def prepared_directory(prepared_root: Path, dataset_id: str, split: str, limit: int, seed: int) -> Path:
  return prepared_root / dataset_id / f"{split}-limit{limit}-seed{seed}"


def prepared_hf_directory(
  prepared_root: Path,
  dataset: str,
  config: str,
  split: str,
  limit: int,
  seed: int,
) -> Path:
  safe_dataset = dataset.replace("/", "__")
  return prepared_root / safe_dataset / config / f"{split}-limit{limit}-seed{seed}"


def prepare_common_voice(args: argparse.Namespace) -> PreparedCommonVoiceDataset:
  if args.source == "mdc-stream":
    return prepare_mdc_stream(args)
  if args.source == "hf-stream":
    return prepare_huggingface_stream(args)
  if args.source == "archive" and args.archive is None:
    raise CommonVoicePrepareError("--source archive requires --archive")
  if args.source == "mdc" and args.archive is not None:
    raise CommonVoicePrepareError("--source mdc does not accept --archive; use --source archive")

  archive_path = args.archive
  if archive_path is None:
    archive_path = download_dataset_archive(
      args.dataset_id,
      args.download_dir,
      args.install_sdk,
      args.max_archive_gb,
      args.allow_large_download,
    )

  if not archive_path.is_file():
    raise CommonVoicePrepareError(f"Archive does not exist: {archive_path}")

  prepared_dir = prepared_directory(args.prepared_root, args.dataset_id, args.split, args.limit, args.seed)
  tsv_path = prepared_dir / f"{args.split}.tsv"
  clips_dir = prepared_dir / "clips"
  manifest_path = prepared_dir / "manifest.json"

  if manifest_path.is_file() and tsv_path.is_file() and clips_dir.is_dir() and not args.overwrite_sample:
    return PreparedCommonVoiceDataset(archive_path, prepared_dir, tsv_path, clips_dir, manifest_path)

  if prepared_dir.exists() and args.overwrite_sample:
    remove_prepared_directory(prepared_dir)

  prepared_dir.mkdir(parents=True, exist_ok=True)
  clips_dir.mkdir(parents=True, exist_ok=True)

  with tarfile.open(archive_path, mode="r:*") as archive:
    split_member, delimiter = split_table_member(archive, args.split)
    rows, fieldnames = sample_rows(
      archive,
      split_member,
      args.split,
      args.limit,
      args.seed,
      args.sample_strategy,
      delimiter=delimiter,
    )
    extract_sample_clips(archive, split_member, rows, clips_dir)
    update_rows_to_prepared_wav(rows)
    write_sample_tsv(tsv_path, rows, fieldnames)

  write_manifest(
    manifest_path,
    {
      "archive_path": str(archive_path),
      "dataset_id": args.dataset_id,
      "split": args.split,
      "limit": args.limit,
      "seed": args.seed,
      "prepared_dir": str(prepared_dir),
      "tsv_path": str(tsv_path),
      "clips_dir": str(clips_dir),
    },
  )

  return PreparedCommonVoiceDataset(archive_path, prepared_dir, tsv_path, clips_dir, manifest_path)


def prepare_mdc_stream(args: argparse.Namespace) -> PreparedCommonVoiceDataset:
  prepared_dir = prepared_directory(args.prepared_root, args.dataset_id, args.split, args.limit, args.seed)
  tsv_path = prepared_dir / f"{args.split}.tsv"
  clips_dir = prepared_dir / "clips"
  manifest_path = prepared_dir / "manifest.json"

  if manifest_path.is_file() and tsv_path.is_file() and clips_dir.is_dir() and not args.overwrite_sample:
    return PreparedCommonVoiceDataset(Path("mdc-stream"), prepared_dir, tsv_path, clips_dir, manifest_path)

  if prepared_dir.exists() and args.overwrite_sample:
    remove_prepared_directory(prepared_dir)

  prepared_dir.mkdir(parents=True, exist_ok=True)
  clips_dir.mkdir(parents=True, exist_ok=True)

  download_plan = mdc_download_plan(args.dataset_id, args.download_dir, args.install_sdk)
  bytes_read = stream_mdc_sample(
    download_url=download_plan.download_url,
    split=args.split,
    limit=args.limit,
    seed=args.seed,
    sample_strategy=args.sample_strategy,
    tsv_path=tsv_path,
    clips_dir=clips_dir,
    max_stream_gb=args.max_stream_gb,
  )

  write_manifest(
    manifest_path,
    {
      "archive_filename": download_plan.filename,
      "archive_size_bytes": download_plan.size_bytes,
      "compressed_bytes_read": bytes_read,
      "dataset_id": args.dataset_id,
      "source": "mdc-stream",
      "split": args.split,
      "limit": args.limit,
      "seed": args.seed,
      "sample_strategy": args.sample_strategy,
      "prepared_dir": str(prepared_dir),
      "tsv_path": str(tsv_path),
      "clips_dir": str(clips_dir),
    },
  )

  return PreparedCommonVoiceDataset(Path("mdc-stream"), prepared_dir, tsv_path, clips_dir, manifest_path)


def prepare_huggingface_stream(args: argparse.Namespace) -> PreparedCommonVoiceDataset:
  ensure_huggingface_streaming_dependencies(args.install_sdk)
  from datasets import Audio, load_dataset  # type: ignore

  prepared_dir = prepared_hf_directory(
    args.prepared_root,
    args.hf_dataset,
    args.hf_config,
    args.split,
    args.limit,
    args.seed,
  )
  tsv_path = prepared_dir / f"{args.split}.tsv"
  clips_dir = prepared_dir / "clips"
  manifest_path = prepared_dir / "manifest.json"

  if manifest_path.is_file() and tsv_path.is_file() and clips_dir.is_dir() and not args.overwrite_sample:
    return PreparedCommonVoiceDataset(Path("hf-stream"), prepared_dir, tsv_path, clips_dir, manifest_path)

  if prepared_dir.exists() and args.overwrite_sample:
    remove_prepared_directory(prepared_dir)

  prepared_dir.mkdir(parents=True, exist_ok=True)
  clips_dir.mkdir(parents=True, exist_ok=True)

  dataset = load_dataset(
    args.hf_dataset,
    args.hf_config,
    split=args.split,
    streaming=True,
    trust_remote_code=True,
  )
  dataset = dataset.cast_column("audio", Audio(sampling_rate=16_000))
  dataset = dataset.shuffle(seed=args.seed, buffer_size=args.hf_shuffle_buffer)

  rows = []
  for index, sample in enumerate(dataset.take(args.limit), start=1):
    rows.append(write_hf_sample(sample, index, clips_dir))

  if len(rows) < args.limit:
    raise CommonVoicePrepareError(
      f"Requested {args.limit} samples, but only streamed {len(rows)} samples"
    )

  fieldnames = ["client_id", "path", "sentence", "text"]
  write_sample_tsv(tsv_path, rows, fieldnames)
  write_manifest(
    manifest_path,
    {
      "archive_path": "hf-stream",
      "source": "hf-stream",
      "hf_dataset": args.hf_dataset,
      "hf_config": args.hf_config,
      "split": args.split,
      "limit": args.limit,
      "seed": args.seed,
      "prepared_dir": str(prepared_dir),
      "tsv_path": str(tsv_path),
      "clips_dir": str(clips_dir),
    },
  )

  return PreparedCommonVoiceDataset(Path("hf-stream"), prepared_dir, tsv_path, clips_dir, manifest_path)


def write_hf_sample(sample, index: int, clips_dir: Path) -> dict[str, str]:
  import soundfile as sf  # type: ignore

  sentence = str(sample.get("sentence") or sample.get("text") or "").strip()
  if not sentence:
    raise CommonVoicePrepareError(f"Streamed sample {index} has no transcript")

  audio = sample.get("audio") or {}
  array = audio.get("array")
  sampling_rate = audio.get("sampling_rate")
  if array is None or sampling_rate is None:
    raise CommonVoicePrepareError(f"Streamed sample {index} has no decoded audio")

  clip_name = f"hf_common_voice_{index:05d}.wav"
  sf.write(clips_dir / clip_name, array, int(sampling_rate))

  return {
    "client_id": str(sample.get("client_id") or sample.get("speaker_id") or ""),
    "path": clip_name,
    "sentence": sentence,
  }


def remove_prepared_directory(path: Path) -> None:
  for child in sorted(path.rglob("*"), reverse=True):
    if child.is_file() or child.is_symlink():
      child.unlink()
    elif child.is_dir():
      child.rmdir()
  path.rmdir()


def split_table_member(archive: tarfile.TarFile, split: str) -> tuple[tarfile.TarInfo, str]:
  split_name = f"{split}.tsv"
  matches = [
    member
    for member in archive.getmembers()
    if member.isfile() and PurePosixPath(member.name).name == split_name
  ]
  if matches:
    return sorted(matches, key=lambda member: member.name)[0], "\t"

  tsv_members = [
    member
    for member in archive.getmembers()
    if member.isfile() and PurePosixPath(member.name).suffix.lower() == ".tsv"
  ]
  if tsv_members:
    return sorted(tsv_members, key=lambda member: member.name)[0], "\t"

  csv_members = [
    member
    for member in archive.getmembers()
    if member.isfile() and PurePosixPath(member.name).suffix.lower() == ".csv"
  ]
  if csv_members:
    return sorted(csv_members, key=lambda member: member.name)[0], ","

  raise CommonVoicePrepareError(
    f"Archive does not contain {split_name}, another TSV, or a CSV metadata file"
  )


def split_tsv_member(archive: tarfile.TarFile, split: str) -> tarfile.TarInfo:
  member, _delimiter = split_table_member(archive, split)
  return member


def sample_rows(
  archive: tarfile.TarFile,
  member: tarfile.TarInfo,
  split: str,
  limit: int,
  seed: int,
  sample_strategy: str,
  *,
  delimiter: str = "\t",
) -> tuple[list[dict[str, str]], list[str]]:
  extracted = archive.extractfile(member)
  if extracted is None:
    raise CommonVoicePrepareError(f"Unable to read {member.name}")

  return sample_rows_from_file(
    extracted,
    split,
    limit,
    seed,
    sample_strategy,
    delimiter=delimiter,
  )


def resolve_fieldnames(fieldnames: Sequence[str] | None) -> tuple[list[str], str, str]:
  if fieldnames is None:
    raise CommonVoicePrepareError("TSV file is empty or missing a header row")
  path_column = next((column for column in PATH_COLUMNS if column in fieldnames), None)
  if path_column is None:
    expected = ", ".join(PATH_COLUMNS)
    raise CommonVoicePrepareError(f"TSV file must contain one of these audio path columns: {expected}")
  text_column = next((column for column in TEXT_COLUMNS if column in fieldnames), None)
  if text_column is None:
    expected = ", ".join(TEXT_COLUMNS)
    raise CommonVoicePrepareError(f"TSV file must contain one of these text columns: {expected}")
  return canonical_fieldnames(fieldnames), path_column, text_column


def canonical_fieldnames(fieldnames: Sequence[str]) -> list[str]:
  result = list(fieldnames)
  if CANONICAL_PATH_COLUMN not in result:
    result.append(CANONICAL_PATH_COLUMN)
  if CANONICAL_TEXT_COLUMN not in result:
    result.append(CANONICAL_TEXT_COLUMN)
  return result


def canonicalize_row(row: dict[str, str], path_column: str, text_column: str) -> dict[str, str]:
  canonical = dict(row)
  canonical[CANONICAL_PATH_COLUMN] = normalize_clip_filename((row.get(path_column) or "").strip())
  canonical[CANONICAL_TEXT_COLUMN] = (row.get(text_column) or "").strip()
  return canonical


def normalize_clip_filename(relative_path: str) -> str:
  """Ensure clip filenames include an extension (Effect AI CSV uses bare IPFS CIDs)."""
  if not relative_path:
    return relative_path
  if PurePosixPath(relative_path).suffix:
    return relative_path
  return f"{relative_path}.mp3"


def prepared_wav_filename(relative_path: str) -> str:
  path = PurePosixPath(relative_path)
  if path.suffix.lower() == ".wav":
    return relative_path
  return str(path.with_suffix(".wav"))


def update_rows_to_prepared_wav(rows: list[dict[str, str]]) -> None:
  for row in rows:
    source_path = (row.get(CANONICAL_PATH_COLUMN) or "").strip()
    row[CANONICAL_PATH_COLUMN] = prepared_wav_filename(source_path)


def convert_to_16k_mono_wav(source: Path, dest: Path) -> None:
  dest.parent.mkdir(parents=True, exist_ok=True)
  if sys.platform == "darwin":
    afconvert = shutil.which("afconvert")
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
    raise CommonVoicePrepareError(
      "Need afconvert (macOS) or ffmpeg on PATH to convert clips to 16 kHz mono WAV"
    )
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
    raise CommonVoicePrepareError(
      f"ffmpeg failed for {source}:\n{completed.stderr.strip()}"
    )


def archive_clip_member_names(split_parent: PurePosixPath, relative_audio_path: str) -> list[str]:
  relative_variants = [relative_audio_path]
  if PurePosixPath(relative_audio_path).suffix == "":
    relative_variants.append(f"{relative_audio_path}.mp3")
  prefixes = [
    split_parent / "clips",
    split_parent / "audio",
    split_parent / "audios",
    split_parent,
  ]
  names: list[str] = []
  for prefix in prefixes:
    for relative in relative_variants:
      for candidate in (str(prefix / relative),):
        names.append(candidate)
        if candidate and not candidate.startswith("./"):
          names.append(f"./{candidate}")
  return names


def find_archive_clip_member(
  archive: tarfile.TarFile,
  split_parent: PurePosixPath,
  relative_audio_path: str,
) -> tuple[tarfile.TarInfo, str]:
  last_name = relative_audio_path
  for member_name in archive_clip_member_names(split_parent, relative_audio_path):
    last_name = member_name
    try:
      return archive.getmember(member_name), member_name
    except KeyError:
      continue
  raise CommonVoicePrepareError(f"Archive is missing sampled clip: {last_name}")


def write_sample_tsv(path: Path, rows: list[dict[str, str]], fieldnames: list[str]) -> None:
  with path.open("w", encoding="utf-8", newline="") as output_file:
    writer = csv.DictWriter(output_file, fieldnames=fieldnames, delimiter="\t")
    writer.writeheader()
    writer.writerows(rows)


def extract_sample_clips(
  archive: tarfile.TarFile,
  split_member: tarfile.TarInfo,
  rows: list[dict[str, str]],
  clips_dir: Path,
) -> None:
  split_parent = PurePosixPath(split_member.name).parent

  for row in rows:
    relative_audio_path = (row.get(CANONICAL_PATH_COLUMN) or "").strip()
    clip_member, member_name = find_archive_clip_member(
      archive,
      split_parent,
      relative_audio_path,
    )

    if not clip_member.isfile():
      raise CommonVoicePrepareError(f"Sampled clip is not a file: {member_name}")

    write_clip(
      archive,
      clip_member,
      clips_dir / prepared_wav_filename(relative_audio_path),
    )


def stream_mdc_sample(
  download_url: str,
  split: str,
  limit: int,
  seed: int,
  sample_strategy: str,
  tsv_path: Path,
  clips_dir: Path,
  max_stream_gb: float,
) -> int:
  import requests

  max_stream_bytes = int(max_stream_gb * 1024 * 1024 * 1024)
  with requests.get(download_url, stream=True, timeout=(10, 60)) as response:
    response.raise_for_status()
    counting_stream = CountingReader(response.raw, max_bytes=max_stream_bytes)
    with tarfile.open(fileobj=counting_stream, mode="r|gz") as archive:
      split_member, delimiter = next_stream_table_member(archive, split)
      rows, fieldnames = sample_rows_from_stream(
        archive,
        split_member,
        split,
        limit,
        seed,
        sample_strategy,
        delimiter=delimiter,
      )
      extract_streamed_clips(archive, split_member, rows, clips_dir)
      update_rows_to_prepared_wav(rows)
      write_sample_tsv(tsv_path, rows, fieldnames)
    return counting_stream.bytes_read


def next_stream_table_member(archive: tarfile.TarFile, split: str) -> tuple[tarfile.TarInfo, str]:
  split_name = f"{split}.tsv"
  for member in archive:
    if not member.isfile():
      continue
    name = PurePosixPath(member.name).name
    if name == split_name:
      return member, "\t"
    if name.endswith(".csv"):
      return member, ","
  raise CommonVoicePrepareError(f"Archive stream does not contain {split_name} or a CSV metadata file")


def next_stream_member(archive: tarfile.TarFile, split: str) -> tarfile.TarInfo:
  member, _delimiter = next_stream_table_member(archive, split)
  return member


def sample_rows_from_stream(
  archive: tarfile.TarFile,
  member: tarfile.TarInfo,
  split: str,
  limit: int,
  seed: int,
  sample_strategy: str,
  *,
  delimiter: str = "\t",
) -> tuple[list[dict[str, str]], list[str]]:
  extracted = archive.extractfile(member)
  if extracted is None:
    raise CommonVoicePrepareError(f"Unable to read {member.name}")

  return sample_rows_from_file(
    extracted,
    split,
    limit,
    seed,
    sample_strategy,
    delimiter=delimiter,
  )


def sample_rows_from_file(
  fileobj,
  split: str,
  limit: int,
  seed: int,
  sample_strategy: str,
  *,
  delimiter: str = "\t",
) -> tuple[list[dict[str, str]], list[str]]:
  rng = random.Random(seed)
  reservoir: list[dict[str, str]] = []
  eligible_rows = 0

  table_file = codecs.getreader("utf-8")(fileobj)
  reader = csv.DictReader(table_file, delimiter=delimiter)
  fieldnames, path_column, text_column = resolve_fieldnames(reader.fieldnames)
  filter_by_split = "split" in fieldnames

  for row in reader:
    if filter_by_split and (row.get("split") or split).strip() != split:
      continue
    if not (row.get(path_column) or "").strip():
      continue
    if not (row.get(text_column) or "").strip():
      continue
    row = canonicalize_row(row, path_column, text_column)

    eligible_rows += 1
    if sample_strategy == "first":
      reservoir.append(row)
      if len(reservoir) == limit:
        break
      continue

    if len(reservoir) < limit:
      reservoir.append(row)
      continue

    replacement_index = rng.randrange(eligible_rows)
    if replacement_index < limit:
      reservoir[replacement_index] = row

  if eligible_rows < limit:
    raise CommonVoicePrepareError(
      f"Requested {limit} samples, but only found {eligible_rows} eligible rows"
    )

  return reservoir, fieldnames


def extract_streamed_clips(
  archive: tarfile.TarFile,
  split_member: tarfile.TarInfo,
  rows: list[dict[str, str]],
  clips_dir: Path,
) -> None:
  split_parent = PurePosixPath(split_member.name).parent
  wanted_paths = {(row.get(CANONICAL_PATH_COLUMN) or "").strip() for row in rows}
  wanted_members: dict[str, str] = {}
  for path in wanted_paths:
    for member_name in archive_clip_member_names(split_parent, path):
      wanted_members[member_name] = normalize_clip_filename(path)
  extracted_paths: set[str] = set()

  for member in archive:
    relative_audio_path = wanted_members.get(member.name)
    if relative_audio_path is None and member.name.startswith("./"):
      relative_audio_path = wanted_members.get(member.name[2:])
    if relative_audio_path is None:
      continue
    if not member.isfile():
      raise CommonVoicePrepareError(f"Sampled clip is not a file: {member.name}")

    prepared_path = prepared_wav_filename(relative_audio_path)
    write_clip(archive, member, clips_dir / prepared_path)
    extracted_paths.add(relative_audio_path)
    print(f"Extracted {len(extracted_paths)}/{len(wanted_paths)}: {prepared_path}")
    if extracted_paths == wanted_paths:
      return

  missing = sorted(wanted_paths - extracted_paths)
  raise CommonVoicePrepareError(
    "Archive stream ended before all sampled clips were found: " + ", ".join(missing[:5])
  )


def write_clip(archive: tarfile.TarFile, member: tarfile.TarInfo, destination: Path) -> None:
  extracted = archive.extractfile(member)
  if extracted is None:
    raise CommonVoicePrepareError(f"Unable to extract sampled clip: {member.name}")

  member_suffix = PurePosixPath(member.name).suffix or ".bin"
  with tempfile.NamedTemporaryFile(suffix=member_suffix, delete=False) as temp_file:
    temp_path = Path(temp_file.name)
    shutil_copyfileobj(extracted, temp_file)

  try:
    if destination.suffix.lower() == ".wav":
      convert_to_16k_mono_wav(temp_path, destination)
      return

    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(temp_path, destination)
  finally:
    temp_path.unlink(missing_ok=True)


class CountingReader:
  def __init__(self, raw, max_bytes: int):
    self.raw = raw
    self.max_bytes = max_bytes
    self.bytes_read = 0

  def read(self, size: int = -1):
    chunk = self.raw.read(size)
    self.bytes_read += len(chunk)
    if self.bytes_read > self.max_bytes:
      raise CommonVoicePrepareError(
        f"Stopped after streaming {self.bytes_read / (1024 * 1024 * 1024):.2f} GB. "
        "Increase --max-stream-gb if you want to keep scanning this archive."
      )
    return chunk


def shutil_copyfileobj(source, destination) -> None:
  while True:
    chunk = source.read(1024 * 1024)
    if not chunk:
      return
    destination.write(chunk)


def write_manifest(path: Path, payload: dict[str, object]) -> None:
  path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def print_result(result: PreparedCommonVoiceDataset, output_json: bool) -> None:
  if output_json:
    print(result.manifest_path.read_text(encoding="utf-8").strip())
    return

  print(f"Archive: {result.archive_path}")
  print(f"Prepared: {result.prepared_dir}")
  print(f"TSV: {result.tsv_path}")
  print(f"Clips: {result.clips_dir}")
  print(f"Manifest: {result.manifest_path}")


def main(argv: Sequence[str] | None = None) -> int:
  load_local_env_files()
  parser = build_parser()
  args = parser.parse_args(argv)
  try:
    result = prepare_common_voice(args)
    print_result(result, args.json)
    return 0
  except CommonVoicePrepareError as error:
    print(f"error: {error}", file=sys.stderr)
    return 1


if __name__ == "__main__":
  raise SystemExit(main())
