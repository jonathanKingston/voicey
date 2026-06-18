#!/usr/bin/env python3
"""Compare batch vs incremental Voicey runners on read-aloud filename clips.

Uses Session Archive WAVs referenced by Benchmarks/readaloud_steering_corpus.json.
Scores reference token recall (not LibriSpeech WER). macOS + built Voicey required.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

from eval_readaloud_artificial_steering import default_archive_root, load_record
from readaloud_corpus_lib import clips_from_manifest, load_corpus_manifest
from sweep_steering_caps import reference_token_recall, resolve_voicey

DEFAULT_BINARY = REPO_ROOT / ".build/debug/Voicey"
FILENAME_CATEGORIES = frozenset(
    {
        "filename_bare",
        "filename_sentence",
        "filename_alt_symbol",
        "filename_homophone",
    }
)


def symlink_clip(source_wav: Path, clips_dir: Path, name: str) -> Path:
    target = clips_dir / name
    if target.exists() or target.is_symlink():
        target.unlink()
    target.symlink_to(source_wav.resolve())
    return target


def write_tsv(path: Path, *, audio_name: str, reference: str) -> None:
    path.write_text(f"client_id\tpath\treference\nlocal\t{audio_name}\t{reference}\n", encoding="utf-8")


def run_runner(
    *,
    binary: Path,
    command: str,
    model: str,
    tsv: Path,
    clips_dir: Path,
    extra_args: tuple[str, ...] = (),
) -> str:
    completed = subprocess.run(
        [
            str(binary),
            command,
            "--model",
            model,
            "--tsv",
            str(tsv),
            "--clips-dir",
            str(clips_dir),
            *extra_args,
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        raise RuntimeError(completed.stderr.strip() or completed.stdout.strip())
    lines = [line for line in completed.stdout.splitlines() if line.strip()]
    if not lines:
        raise RuntimeError("runner returned no JSONL output")
    payload = json.loads(lines[0])
    return (payload.get("rawText") or payload.get("text") or "").strip()


def evaluate_clip(
    *,
    binary: Path,
    model: str,
    archive_root: Path,
    clip,
    temp_root: Path,
    glossary_file: Path | None,
) -> dict:
    rec = load_record(archive_root, clip.id_prefix)
    wav = archive_root / rec["audio_path"]
    if not wav.is_file():
        return {
            "id_prefix": clip.id_prefix,
            "script": clip.script,
            "category": clip.category,
            "status": "missing_wav",
        }

    clips_dir = temp_root / clip.id_prefix
    clips_dir.mkdir(parents=True, exist_ok=True)
    audio_name = f"{clip.id_prefix}.wav"
    symlink_clip(wav, clips_dir, audio_name)
    tsv = temp_root / f"{clip.id_prefix}.tsv"
    write_tsv(tsv, audio_name=audio_name, reference=clip.reference)

    steer_args: tuple[str, ...] = ()
    if glossary_file is not None:
        steer_args = ("--glossary-steer", "--glossary-file", str(glossary_file))

    batch_raw = run_runner(
        binary=binary,
        command="benchmark-transcribe-batch",
        model=model,
        tsv=tsv,
        clips_dir=clips_dir,
        extra_args=steer_args,
    )
    incremental_raw = run_runner(
        binary=binary,
        command="benchmark-transcribe-incremental-batch",
        model=model,
        tsv=tsv,
        clips_dir=clips_dir,
        extra_args=(),
    )

    return {
        "id_prefix": clip.id_prefix,
        "script": clip.script,
        "category": clip.category,
        "reference": clip.reference,
        "status": "ok",
        "batch_raw": batch_raw,
        "incremental_raw": incremental_raw,
        "batch_token_recall": reference_token_recall(batch_raw, clip.reference),
        "incremental_token_recall": reference_token_recall(incremental_raw, clip.reference),
        "expect_coordinator_swift": clip.expect_coordinator_swift,
    }


def write_summary(path: Path, rows: list[dict]) -> None:
    lines = [
        "# Read-aloud runtime matrix (batch vs incremental)",
        "",
        "| script | category | batch recall | incremental recall | batch raw | incremental raw |",
        "| --- | --- | ---: | ---: | --- | --- |",
    ]
    for row in rows:
        if row.get("status") != "ok":
            lines.append(f"| {row.get('script', '?')} | {row.get('category', '?')} | error | error | — | — |")
            continue
        lines.append(
            "| "
            + " | ".join(
                [
                    row["script"],
                    row["category"],
                    f"{row['batch_token_recall']:.2f}",
                    f"{row['incremental_token_recall']:.2f}",
                    row["batch_raw"].replace("|", "\\|"),
                    row["incremental_raw"].replace("|", "\\|"),
                ]
            )
            + " |"
        )
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive-root", type=Path, default=default_archive_root())
    parser.add_argument("--binary", type=Path, default=DEFAULT_BINARY)
    parser.add_argument("--model", default="qwen3-asr-1.7b-bf16")
    parser.add_argument(
        "--corpus",
        type=Path,
        default=REPO_ROOT / "Benchmarks" / "readaloud_steering_corpus.json",
    )
    parser.add_argument(
        "--glossary-file",
        type=Path,
        default=REPO_ROOT
        / "benchmark-data/common-voice/prepared/librispeech_clean/test-limit200-seed20260506/eval_proper_noun_glossary.txt",
    )
    parser.add_argument(
        "--categories",
        nargs="*",
        default=sorted(FILENAME_CATEGORIES),
        help="Corpus categories to include (default: filename_*).",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=REPO_ROOT / "benchmark-results" / "readaloud-runtime-matrix",
    )
    args = parser.parse_args()

    if not args.binary.is_file():
        raise SystemExit(f"missing Voicey binary at {args.binary} (run make build)")

    manifest = load_corpus_manifest(args.corpus)
    wanted_categories = set(args.categories)
    clips = [
        clip
        for clip in clips_from_manifest(manifest, require_id=True)
        if clip.category in wanted_categories
    ]
    if not clips:
        raise SystemExit("no recorded clips matched category filters")

    glossary_file = args.glossary_file if args.glossary_file.is_file() else None
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    output_dir = args.output_dir / timestamp
    output_dir.mkdir(parents=True, exist_ok=True)

    rows: list[dict] = []
    with tempfile.TemporaryDirectory(prefix="voicey-readaloud-runtime-") as temp_dir:
        temp_root = Path(temp_dir)
        for clip in clips:
            print(f"[runtime] {clip.script} ({clip.category})", flush=True)
            try:
                row = evaluate_clip(
                    binary=args.binary,
                    model=args.model,
                    archive_root=args.archive_root,
                    clip=clip,
                    temp_root=temp_root,
                    glossary_file=glossary_file,
                )
            except RuntimeError as error:
                row = {
                    "id_prefix": clip.id_prefix,
                    "script": clip.script,
                    "category": clip.category,
                    "status": "error",
                    "error": str(error),
                }
            rows.append(row)
            if row.get("status") == "ok":
                print(
                    f"  batch={row['batch_token_recall']:.2f} "
                    f"incremental={row['incremental_token_recall']:.2f}",
                    flush=True,
                )
            else:
                print(f"  {row.get('status')}: {row.get('error', row.get('status'))}", flush=True)

    payload = {
        "created_at": timestamp,
        "model": args.model,
        "glossary_file": str(glossary_file) if glossary_file else None,
        "clips": rows,
    }
    json_path = output_dir / "summary.json"
    json_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    write_summary(output_dir / "summary.md", rows)
    print(f"Summary: {json_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
