#!/usr/bin/env python3
"""Compare in-process vs multiprocess benchmark-transcribe over a TSV clip list."""

from __future__ import annotations

import argparse
import csv
import json
import statistics
import subprocess
import sys
from pathlib import Path


def run_transcribe(
    voicey: Path,
    model: str,
    audio: Path,
    runtime: str,
    warmup: int,
) -> dict:
    cmd = [
        str(voicey),
        "benchmark-transcribe",
        "--model",
        model,
        "--audio",
        str(audio),
        "--json",
        "--post-process",
        "--runtime",
        runtime,
        "--warmup",
        str(warmup),
    ]
    proc = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or f"exit {proc.returncode}")
    line = proc.stdout.strip().splitlines()[-1]
    return json.loads(line)


def load_rows(tsv: Path, clips_dir: Path) -> list[tuple[str, Path]]:
    rows: list[tuple[str, Path]] = []
    with tsv.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        for row in reader:
            rel = row.get("path") or row.get("audio_file") or ""
            if not rel:
                continue
            audio = clips_dir / rel
            if not audio.is_file():
                raise FileNotFoundError(audio)
            rows.append((rel, audio))
    return rows


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--voicey", type=Path, default=Path(".build/debug/Voicey"))
    parser.add_argument("--model", default="qwen3-asr-0.6b-6bit")
    parser.add_argument("--tsv", type=Path, required=True)
    parser.add_argument("--clips-dir", type=Path, required=True)
    parser.add_argument("--warmup", type=int, default=1)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    if not args.voicey.is_file():
        print(f"error: missing Voicey binary: {args.voicey}", file=sys.stderr)
        return 1

    rows = load_rows(args.tsv, args.clips_dir)
    results: list[dict] = []

    for index, (rel, audio) in enumerate(rows, start=1):
        print(f"[{index}/{len(rows)}] {rel}", file=sys.stderr)
        in_payload = run_transcribe(
            args.voicey, args.model, audio, "in-process", args.warmup
        )
        mp_payload = run_transcribe(
            args.voicey, args.model, audio, "multiprocess", args.warmup
        )
        in_rtf = float(in_payload.get("realTimeFactor") or 0)
        mp_rtf = float(mp_payload.get("realTimeFactor") or 0)
        results.append(
            {
                "path": rel,
                "rawTextMatch": in_payload.get("rawText") == mp_payload.get("rawText"),
                "textMatch": in_payload.get("text") == mp_payload.get("text"),
                "inProcessRTF": in_rtf,
                "multiprocessRTF": mp_rtf,
                "rtfRatio": (mp_rtf / in_rtf) if in_rtf > 0 else None,
                "inProcessProcessingSeconds": in_payload.get("processingSeconds"),
                "multiprocessProcessingSeconds": mp_payload.get("processingSeconds"),
                "audioSeconds": in_payload.get("audioSeconds"),
            }
        )

    ratios = [r["rtfRatio"] for r in results if r.get("rtfRatio") is not None]
    summary = {
        "model": args.model,
        "warmup": args.warmup,
        "clipCount": len(results),
        "rawTextMatches": sum(1 for r in results if r["rawTextMatch"]),
        "textMatches": sum(1 for r in results if r["textMatch"]),
        "rtfRatioMedian": statistics.median(ratios) if ratios else None,
        "rtfRatioMean": statistics.mean(ratios) if ratios else None,
        "rtfRatioMax": max(ratios) if ratios else None,
        "rtfRatioMin": min(ratios) if ratios else None,
        "clipsOver105Ratio": sum(1 for r in ratios if r > 1.05),
    }

    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w", encoding="utf-8") as handle:
        handle.write(json.dumps({"summary": summary, "clips": results}, indent=2))
        handle.write("\n")

    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
