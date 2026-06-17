#!/usr/bin/env python3
"""Broad steering analysis: read-aloud Session Archive + Common Voice in one report.

Uses the blended manual glossary from Benchmarks/readaloud_steering_corpus.json for
read-aloud replay and CV glossary_blended mode. Writes benchmark-results/
broad-steering-analysis.json (gitignored).

Requires macOS + Rust runtime; CV slice optional (--skip-common-voice if missing data).
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

from eval_readaloud_artificial_steering import default_archive_root, run_eval
from readaloud_corpus_lib import blended_glossary, clips_from_manifest, load_corpus_manifest, pending_clips


def summarize_read_aloud(report: dict) -> dict:
    clips = report.get("clips") or []
    if not clips:
        return {"clip_count": 0}

    def mean_delta(mode: str) -> float:
        deltas = []
        for clip in clips:
            none_d = clip["modes"]["none"]["reference_levenshtein"]
            if mode not in clip["modes"]:
                continue
            deltas.append(clip["modes"][mode]["reference_levenshtein"] - none_d)
        return sum(deltas) / len(deltas) if deltas else 0.0

    by_category: dict[str, list[float]] = {}
    for clip in clips:
        cat = clip.get("category") or "unknown"
        by_category.setdefault(cat, []).append(clip["modes"]["none"]["reference_levenshtein"])

    glossary_hits = sum(
        1
        for clip in clips
        if clip["modes"].get("glossary_artificial", {}).get("expect_glossary_token_met") is True
    )
    glossary_checked = sum(
        1
        for clip in clips
        if clip["modes"].get("glossary_artificial", {}).get("expect_glossary_token_met") is not None
    )

    return {
        "clip_count": len(clips),
        "mean_ref_distance_none": sum(c["modes"]["none"]["reference_levenshtein"] for c in clips) / len(clips),
        "mean_ref_distance_glossary": sum(
            c["modes"]["glossary_artificial"]["reference_levenshtein"] for c in clips
        )
        / len(clips),
        "mean_glossary_improvement": -mean_delta("glossary_artificial"),
        "glossary_token_hits": glossary_hits,
        "glossary_token_checked": glossary_checked,
        "by_category_mean_none_distance": {
            cat: sum(vals) / len(vals) for cat, vals in sorted(by_category.items())
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", default="qwen3-asr-1.7b-bf16")
    parser.add_argument("--archive-root", type=Path, default=default_archive_root())
    parser.add_argument("--corpus", type=Path, default=REPO_ROOT / "Benchmarks" / "readaloud_steering_corpus.json")
    parser.add_argument("--skip-common-voice", action="store_true")
    parser.add_argument("--prepare-common-voice", action="store_true")
    parser.add_argument(
        "--out",
        type=Path,
        default=REPO_ROOT / "benchmark-results" / "broad-steering-analysis.json",
    )
    parser.add_argument(
        "--readaloud-out",
        type=Path,
        default=REPO_ROOT / "benchmark-results" / "readaloud-artificial-steering.json",
    )
    parser.add_argument(
        "--common-voice-out",
        type=Path,
        default=REPO_ROOT / "benchmark-results" / "common-voice-steering.json",
    )
    args = parser.parse_args()

    manifest = load_corpus_manifest(args.corpus)
    glossary = blended_glossary(manifest)
    clips = clips_from_manifest(manifest, require_id=True)

    print(f"Blended glossary ({len(glossary.split(','))} terms): {glossary[:100]}…", file=sys.stderr)
    pending = pending_clips(manifest)
    if pending:
        print(f"Pending recordings: {len(pending)} — see Benchmarks/ReadAloudSteeringRecording.md", file=sys.stderr)

    readaloud_report = run_eval(
        archive_root=args.archive_root,
        model=args.model,
        glossary=glossary,
        clips=clips,
    )
    args.readaloud_out.parent.mkdir(parents=True, exist_ok=True)
    args.readaloud_out.write_text(json.dumps(readaloud_report, indent=2), encoding="utf-8")
    print(f"Wrote {args.readaloud_out}", file=sys.stderr)

    cv_report: dict | None = None
    if not args.skip_common_voice:
        cv_cmd = [
            sys.executable,
            str(REPO_ROOT / "scripts" / "eval_common_voice_steering.py"),
            "--model",
            args.model,
            "--out",
            str(args.common_voice_out),
        ]
        if args.prepare_common_voice:
            cv_cmd.append("--prepare")
        completed = subprocess.run(cv_cmd, check=False)
        if completed.returncode != 0:
            print("Common Voice eval failed or skipped; see stderr above.", file=sys.stderr)
        elif args.common_voice_out.is_file():
            cv_report = json.loads(args.common_voice_out.read_text(encoding="utf-8"))

    broad = {
        "model": args.model,
        "glossary_blended": glossary,
        "corpus_manifest": str(args.corpus),
        "read_aloud": {
            "path": str(args.readaloud_out),
            "summary": summarize_read_aloud(readaloud_report),
            "pending_script_lines": [row["script"] for row in pending],
        },
        "common_voice": None,
        "cross_cut": {},
    }

    if cv_report:
        cv_summary = cv_report.get("summary") or {}
        broad["common_voice"] = {
            "path": str(args.common_voice_out),
            "summary": cv_summary,
        }
        broad["cross_cut"] = {
            "interpretation": (
                "Read-aloud uses scripted references and replay glossary; Common Voice uses "
                "WER vs corpus transcripts. Oracle CV steering is an upper bound; "
                "glossary_blended uses the same manual list as read-aloud."
            ),
            "read_aloud_mean_none_distance": broad["read_aloud"]["summary"].get("mean_ref_distance_none"),
            "common_voice_mean_wer_none": cv_summary.get("mean_wer_none"),
            "common_voice_mean_wer_blended": cv_summary.get("mean_wer_glossary_blended"),
            "common_voice_mean_wer_oracle": cv_summary.get("mean_wer_oracle_reference"),
        }

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(broad, indent=2), encoding="utf-8")

    print("\n=== Broad steering analysis ===", file=sys.stderr)
    ra = broad["read_aloud"]["summary"]
    print(
        f"Read-aloud: n={ra.get('clip_count')} mean_none_d={ra.get('mean_ref_distance_none', 0):.3f} "
        f"glossary_hits={ra.get('glossary_token_hits')}/{ra.get('glossary_token_checked')}",
        file=sys.stderr,
    )
    if broad["common_voice"]:
        cv = broad["common_voice"]["summary"]
        print(
            f"Common Voice: n={cv.get('clip_count')} mean_wer none={cv.get('mean_wer_none', 0):.3f} "
            f"blended={cv.get('mean_wer_glossary_blended', 0):.3f}",
            file=sys.stderr,
        )
    print(f"Wrote {args.out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
