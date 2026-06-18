#!/usr/bin/env python3
"""Export read-aloud corpus clips into a portable local artifact (not for git).

Default output:
  ~/Library/Application Support/Voicey/Artifacts/readaloud-corpus-v3/

Contains WAVs, index slice, corpus manifest copy, and ARTIFACT.json replay hints.
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

from eval_readaloud_artificial_steering import load_record
from readaloud_corpus_lib import DEFAULT_CORPUS_PATH, clips_from_manifest, load_corpus_manifest
from voicey_artifacts_lib import (
    default_artifacts_root,
    default_session_archive_root,
    readaloud_artifact_dir,
)


def export_readaloud(
    *,
    archive_root: Path,
    output_dir: Path,
    corpus_path: Path,
    tag: str | None,
) -> Path:
    manifest = load_corpus_manifest(corpus_path)
    version = int(manifest.get("version") or 0)
    if version <= 0:
        raise SystemExit(f"corpus missing version: {corpus_path}")

    clips = clips_from_manifest(manifest, require_id=True)
    if not clips:
        raise SystemExit("no clips with id_prefix in corpus manifest")

    if output_dir.exists():
        shutil.rmtree(output_dir)
    output_dir.mkdir(parents=True)
    (output_dir / "audio").mkdir()
    (output_dir / "snapshots").mkdir()

    records: list[dict] = []
    for clip in clips:
        rec = load_record(archive_root, clip.id_prefix)
        records.append(rec)
        wav_src = archive_root / rec["audio_path"]
        if not wav_src.is_file():
            raise SystemExit(f"missing WAV for {clip.script} ({clip.id_prefix}): {wav_src}")
        shutil.copy2(wav_src, output_dir / rec["audio_path"])

        snap_rel = rec.get("snapshot_path")
        if snap_rel:
            snap_src = archive_root / snap_rel
            if snap_src.is_file():
                shutil.copy2(snap_src, output_dir / snap_rel)

    with (output_dir / "index.jsonl").open("w", encoding="utf-8") as handle:
        for rec in records:
            handle.write(json.dumps(rec, ensure_ascii=False) + "\n")

    shutil.copy2(corpus_path, output_dir / "corpus_manifest.json")

    meta = {
        "kind": "readaloud-corpus",
        "corpus_version": version,
        "exported_at": datetime.now(timezone.utc).isoformat(),
        "tag": tag,
        "clip_count": len(clips),
        "source_archive_root": str(archive_root),
        "expected_text": "corpus_manifest.json clips[].reference (ground truth)",
        "replay_asr_eval": (
            f"make eval-readaloud-steering ARGS="
            f"\"--archive-root '{output_dir}'\""
        ),
        "replay_delivery_eval": (
            f"make eval-readaloud-delivery-matrix ARGS="
            f"\"--archive-root '{output_dir}'\""
        ),
    }
    (output_dir / "ARTIFACT.json").write_text(
        json.dumps(meta, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    return output_dir


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS_PATH)
    parser.add_argument("--archive-root", type=Path, default=default_session_archive_root())
    parser.add_argument("--output", type=Path, default=None)
    parser.add_argument("--tag", default=None)
    args = parser.parse_args()

    manifest = load_corpus_manifest(args.corpus)
    version = int(manifest.get("version") or 0)
    out = args.output or readaloud_artifact_dir(
        corpus_version=version,
        tag=args.tag,
        artifacts_root=default_artifacts_root(),
    )
    export_readaloud(
        archive_root=args.archive_root,
        output_dir=out,
        corpus_path=args.corpus,
        tag=args.tag,
    )
    print(out)


if __name__ == "__main__":
    main()
