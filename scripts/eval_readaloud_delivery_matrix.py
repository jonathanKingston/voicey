#!/usr/bin/env python3
"""Read-aloud delivery matrix: post-process archived raw ASR vs script reference.

Scores the *paste path* (voicey-text postprocess), not live clipboard contents.
Uses archive raw_text (or partial) plus live steering snapshot/terms from the row.
Ground truth is corpus ``reference`` — same as ASR replay eval.

WAV is required on disk for archive integrity but this script does not re-transcribe
unless raw_text is missing.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

from eval_readaloud_artificial_steering import default_archive_root, load_record, score_transcript
from readaloud_corpus_lib import DEFAULT_CORPUS_PATH, clips_from_manifest, load_corpus_manifest
from sweep_steering_caps import (
    CapConfig,
    build_steering,
    normalized_levenshtein,
    resolve_voicey,
    resolve_worker,
    worker_env,
)
from voicey_jsonl_worker import JsonlWorker

DEFAULT_CAP = CapConfig(max_screen_terms=16, max_terms=48, max_context_chars=512)


def deliverable(text: str) -> bool:
    return text.strip() != ""


def archive_raw_text(rec: dict) -> str:
    raw = (rec.get("raw_text") or "").strip()
    if raw:
        return raw
    partial = (rec.get("partial_transcription") or "").strip()
    if partial:
        return partial
    processed = (rec.get("processed_text") or "").strip()
    return processed


def postprocess(
    text_worker: JsonlWorker,
    *,
    text: str,
    decoder_context: str | None,
    steering_terms: list[str],
) -> str:
    response = text_worker.request(
        {
            "type": "postprocess",
            "text": text,
            "voice_commands_enabled": False,
            "decoder_context": decoder_context,
            "steering_terms": steering_terms,
        }
    )
    if response.get("type") != "postprocess_result" or not response.get("ok"):
        raise RuntimeError(f"postprocess failed: {response}")
    return (response.get("text") or "").strip()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive-root", type=Path, default=default_archive_root())
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS_PATH)
    parser.add_argument(
        "--out",
        type=Path,
        default=REPO_ROOT / "benchmark-results" / "readaloud-delivery-matrix.json",
    )
    args = parser.parse_args()

    manifest = load_corpus_manifest(args.corpus)
    clips = clips_from_manifest(manifest, require_id=True)
    voicey = resolve_voicey()
    text_worker = JsonlWorker(str(resolve_worker("voicey-text")), env=worker_env(voicey))

    rows: list[dict] = []
    regressions = 0
    mismatches = 0

    try:
        for clip in clips:
            row_manifest = next(r for r in manifest["clips"] if r["script"] == clip.script)
            expect_deliverable = row_manifest.get("expect_live_delivery", True)
            rec = load_record(args.archive_root, clip.id_prefix)
            uid = rec["id"].replace("-", "")
            wav = args.archive_root / rec["audio_path"]
            if not wav.is_file():
                raise SystemExit(f"missing WAV: {wav}")

            raw = archive_raw_text(rec)
            if not raw:
                raise SystemExit(f"no raw text for {clip.script} ({clip.id_prefix})")

            snap_path = args.archive_root / "snapshots" / f"{uid}.json"
            snapshot = json.loads(snap_path.read_text()) if snap_path.is_file() else None
            steering = build_steering(
                text_worker,
                DEFAULT_CAP,
                manual_glossary_enabled=bool(rec.get("glossary_enabled")),
                manual_glossary="",
                screen_context_enabled=bool(rec.get("screen_context_enabled")),
                snapshot=snapshot,
            )
            decoder_context = steering.get("decoder_context")
            archived_terms = rec.get("steering_terms") or []
            terms = [str(t) for t in archived_terms] if archived_terms else (steering.get("terms") or [])
            processed = postprocess(
                text_worker,
                text=raw,
                decoder_context=decoder_context,
                steering_terms=terms,
            )
            is_deliverable = deliverable(processed)
            live_processed = (rec.get("processed_text") or "").strip()
            live_outcome = rec.get("outcome")

            if is_deliverable != expect_deliverable:
                mismatches += 1

            entry = {
                "script": clip.script,
                "id_prefix": clip.id_prefix,
                "reference": clip.reference,
                "archive_outcome": live_outcome,
                "expect_live_delivery": expect_deliverable,
                "raw_text": raw,
                "live_processed_text": live_processed,
                "replay_processed_text": processed,
                "replay_deliverable": is_deliverable,
                "delivery_match_expectation": is_deliverable == expect_deliverable,
                **score_transcript(
                    processed if is_deliverable else raw,
                    clip.reference,
                    expect_swift=clip.expect_coordinator_swift,
                    expect_token=clip.expect_glossary_token,
                ),
                "processed_levenshtein_vs_reference": normalized_levenshtein(processed, clip.reference),
            }
            rows.append(entry)
            flag = "OK" if entry["delivery_match_expectation"] else "MISMATCH"
            print(
                f"{flag} {clip.script} deliverable={is_deliverable} "
                f"(expect {expect_deliverable}) live_outcome={live_outcome}",
                file=sys.stderr,
            )
    finally:
        text_worker.close()

    report = {
        "archive_root": str(args.archive_root),
        "corpus": str(args.corpus),
        "delivery_regressions": mismatches,
        "clips": rows,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(f"Wrote {args.out}", file=sys.stderr)
    if mismatches:
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
