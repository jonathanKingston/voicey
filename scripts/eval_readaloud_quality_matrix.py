#!/usr/bin/env python3
"""Run read-aloud steering eval and emit term-recall summary markdown."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]


def aggregate_report(report: dict) -> dict:
    mode_stats: dict[str, dict[str, float]] = {}
    for clip in report.get("clips", []):
        for mode_name, mode in clip.get("modes", {}).items():
            bucket = mode_stats.setdefault(
                mode_name,
                {"recall_sum": 0.0, "levenshtein_sum": 0.0, "count": 0.0},
            )
            bucket["recall_sum"] += float(mode.get("reference_token_recall", 0.0))
            bucket["levenshtein_sum"] += float(mode.get("reference_levenshtein", 0.0))
            bucket["count"] += 1.0
            if mode.get("expect_glossary_token_met") is False:
                bucket["glossary_miss"] = bucket.get("glossary_miss", 0.0) + 1.0

    summary = {}
    for mode_name, bucket in mode_stats.items():
        count = bucket["count"] or 1.0
        summary[mode_name] = {
            "mean_token_recall": bucket["recall_sum"] / count,
            "mean_levenshtein": bucket["levenshtein_sum"] / count,
            "clips": int(count),
            "glossary_misses": int(bucket.get("glossary_miss", 0.0)),
        }
    return summary


def write_summary_markdown(path: Path, summary: dict, *, report_path: Path) -> None:
    lines = [
        "# Read-aloud steering quality matrix",
        "",
        f"Source report: `{report_path}`",
        "",
        "| mode | clips | mean token recall | mean levenshtein | glossary misses |",
        "| --- | ---: | ---: | ---: | ---: |",
    ]
    for mode_name, row in sorted(summary.items()):
        lines.append(
            "| "
            + " | ".join(
                [
                    mode_name,
                    str(row["clips"]),
                    f"{row['mean_token_recall']:.3f}",
                    f"{row['mean_levenshtein']:.3f}",
                    str(row["glossary_misses"]),
                ]
            )
            + " |"
        )
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=REPO_ROOT / "benchmark-results" / "readaloud-quality-matrix",
    )
    args, remainder = parser.parse_known_args()

    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    output_dir = args.output_dir / timestamp
    output_dir.mkdir(parents=True, exist_ok=True)
    report_path = output_dir / "readaloud-artificial-steering.json"

    command = [
        sys.executable,
        str(REPO_ROOT / "scripts" / "eval_readaloud_artificial_steering.py"),
        "--out",
        str(report_path),
        *remainder,
    ]
    completed = subprocess.run(command, check=False)
    if completed.returncode != 0:
        return completed.returncode
    if not report_path.is_file():
        print("error: read-aloud eval did not write report", file=sys.stderr)
        return 1

    report = json.loads(report_path.read_text(encoding="utf-8"))
    summary = aggregate_report(report)
    summary_json = output_dir / "summary.json"
    summary_json.write_text(
        json.dumps({"created_at": timestamp, "modes": summary}, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    write_summary_markdown(output_dir / "summary.md", summary, report_path=report_path)
    print(f"Summary: {summary_json}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
