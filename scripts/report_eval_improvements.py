#!/usr/bin/env python3
"""Aggregate WER/delivery/LM latency from a full-eval output directory."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

from summarize_readaloud_steering_wer import summarize_report


def load_json(path: Path) -> dict | None:
    if not path.is_file():
        return None
    return json.loads(path.read_text(encoding="utf-8"))


def libri_matrix_summaries(eval_dir: Path) -> list[dict]:
    base = eval_dir / "quality-matrix-librispeech-200-all-variants"
    if not base.is_dir():
        return []
    out: list[dict] = []
    for run_dir in sorted(base.iterdir()):
        summary = run_dir / "summary.json"
        if summary.is_file():
            payload = json.loads(summary.read_text(encoding="utf-8"))
            out.append({"run": run_dir.name, "results": payload.get("results", [])})
            continue
        # partial run: merge per-variant json files
        partial = []
        for p in sorted(run_dir.glob("*.json")):
            partial.append(json.loads(p.read_text(encoding="utf-8")))
        if partial:
            out.append({"run": run_dir.name, "results": partial, "partial": True})
    return out


def cv_summary(path: Path) -> dict | None:
    data = load_json(path)
    if not data:
        return None
    return data.get("summary") or data


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "eval_dir",
        type=Path,
        help="benchmark-results/full-eval-* directory",
    )
    parser.add_argument("--out", type=Path, default=None)
    args = parser.parse_args()
    eval_dir = args.eval_dir.resolve()
    if not eval_dir.is_dir():
        print(f"error: missing {eval_dir}", file=sys.stderr)
        return 1

    report: dict = {"eval_dir": str(eval_dir), "sections": {}}

    for model_slug, fname in (
        ("1.7b", "readaloud-steering-qwen3-asr-1.7b-bf16.json"),
        ("0.6b", "readaloud-steering-qwen3-asr-0.6b-6bit.json"),
    ):
        p = eval_dir / fname
        if p.is_file():
            report["sections"][f"read_aloud_wer_{model_slug}"] = summarize_report(p)

    delivery = load_json(eval_dir / "readaloud-delivery-matrix.json")
    if delivery:
        clips = delivery.get("clips", [])
        report["sections"]["delivery"] = {
            "regressions": delivery.get("delivery_regressions"),
            "replay_deliverable": sum(1 for c in clips if c.get("replay_deliverable")),
            "clip_count": len(clips),
        }

    broad = load_json(eval_dir / "broad-steering-with-cv.json")
    if broad:
        report["sections"]["broad"] = broad.get("cross_cut", broad)

    for model_slug, fname in (
        ("1.7b", "common-voice-steering-qwen3-asr-1.7b-bf16.json"),
        ("0.6b", "common-voice-steering-qwen3-asr-0.6b-6bit.json"),
    ):
        s = cv_summary(eval_dir / fname)
        if s:
            report["sections"][f"common_voice_{model_slug}"] = s

    libri = libri_matrix_summaries(eval_dir)
    if libri:
        report["sections"]["librispeech_matrix"] = libri

    text = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(text, encoding="utf-8")
        print(f"Wrote {args.out}", file=sys.stderr)
    else:
        print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
