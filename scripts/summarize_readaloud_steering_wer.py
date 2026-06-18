#!/usr/bin/env python3
"""Macro WER + harness distance from read-aloud artificial steering JSON reports."""

from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import benchmark_common_voice as bcv


def wer(ref: str, hyp: str) -> float:
    return bcv.compute_text_metrics(ref, hyp, False, False).wer


def summarize_report(path: Path) -> dict:
    report = json.loads(path.read_text(encoding="utf-8"))
    modes = ("none", "glossary_artificial", "glossary_and_screen_artificial")
    by_mode: dict[str, list[float]] = {m: [] for m in modes}
    by_mode_cat: dict[str, dict[str, list[float]]] = defaultdict(lambda: {m: [] for m in modes})
    lev_by_mode: dict[str, list[float]] = {m: [] for m in modes}

    for clip in report.get("clips", []):
        ref = clip.get("reference") or ""
        cat = clip.get("category") or "unknown"
        for mode in modes:
            block = clip.get("modes", {}).get(mode)
            if not block:
                continue
            raw = (block.get("raw_text") or "").strip()
            if not raw:
                continue
            by_mode[mode].append(wer(ref, raw))
            by_mode_cat[cat][mode].append(wer(ref, raw))
            lev_by_mode[mode].append(float(block.get("reference_levenshtein", 0.0)))

    def mean(vals: list[float]) -> float | None:
        return sum(vals) / len(vals) if vals else None

    out = {
        "report": str(path),
        "model": report.get("model"),
        "clip_count": len(report.get("clips", [])),
        "mean_wer": {m: mean(by_mode[m]) for m in modes},
        "mean_reference_levenshtein": {m: mean(lev_by_mode[m]) for m in modes},
        "wer_delta_vs_none": {},
        "by_category_mean_wer": {},
    }
    none_wer = out["mean_wer"].get("none")
    for m in modes:
        if m == "none" or none_wer is None or out["mean_wer"][m] is None:
            continue
        out["wer_delta_vs_none"][m] = out["mean_wer"][m] - none_wer
    for cat, buckets in sorted(by_mode_cat.items()):
        out["by_category_mean_wer"][cat] = {m: mean(buckets[m]) for m in modes if buckets[m]}
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reports", nargs="+", type=Path)
    parser.add_argument("--out", type=Path, default=None)
    args = parser.parse_args()

    summaries = [summarize_report(p) for p in args.reports]
    payload = {"summaries": summaries}
    text = json.dumps(payload, indent=2, sort_keys=True) + "\n"
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(text, encoding="utf-8")
        print(f"Wrote {args.out}", file=sys.stderr)
    else:
        print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
