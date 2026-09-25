#!/usr/bin/env python3
"""Replay SessionArchive WAVs via Voicey benchmark-transcribe and compare to index.jsonl."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path


def default_archive_root() -> Path:
    return Path.home() / "Library/Application Support/Voicey/SessionArchive"


def default_voicey_binary(repo_root: Path) -> Path:
    app = repo_root / "Voicey.app/Contents/MacOS/Voicey"
    if app.is_file():
        return app
    debug = repo_root / ".build/debug/Voicey"
    if debug.is_file():
        return debug
    raise SystemExit("Voicey binary not found (run make dev-restart or swift build)")


def transcribe(
    voicey: Path,
    model: str,
    wav: Path,
    *,
    post_process: bool = False,
) -> dict:
    cmd = [
        str(voicey),
        "benchmark-transcribe",
        "--model",
        model,
        "--audio",
        str(wav),
        "--json",
        "--runtime",
        "multiprocess",
        "--warmup",
        "0",
    ]
    if post_process:
        cmd.append("--post-process")
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError((proc.stderr or proc.stdout)[-800:])
    line = proc.stdout.strip().splitlines()[-1]
    return json.loads(line)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive-root", type=Path, default=default_archive_root())
    parser.add_argument(
        "--voicey",
        type=Path,
        default=None,
        help="Path to Voicey binary (default: Voicey.app in repo root)",
    )
    parser.add_argument(
        "--models",
        nargs="+",
        default=["qwen3-asr-1.7b-bf16", "qwen3-asr-0.6b-6bit"],
        help="SpeechModel raw values to compare",
    )
    parser.add_argument("--post-process", action="store_true")
    parser.add_argument("--repeats", type=int, default=1)
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parents[1]
    voicey = args.voicey or default_voicey_binary(repo_root)
    index_path = args.archive_root / "index.jsonl"
    if not index_path.is_file():
        print(f"no index at {index_path}", file=sys.stderr)
        return 1

    records = [json.loads(line) for line in index_path.read_text().splitlines() if line.strip()]
    print(f"Archive: {args.archive_root} ({len(records)} utterances)")
    print(f"Voicey: {voicey}")
    print(f"Models: {', '.join(args.models)}\n")

    any_mismatch = False
    for rec in records:
        wav = args.archive_root / rec["audio_path"]
        archived_raw = rec.get("raw_text", "")
        print(f"— {rec['id'][:8]}… ({rec.get('audio_seconds', 0):.1f}s) archived={archived_raw!r}")
        if not wav.is_file():
            print(f"  missing {wav}")
            any_mismatch = True
            continue
        for model in args.models:
            texts: list[str] = []
            for _ in range(max(1, args.repeats)):
                payload = transcribe(voicey, model, wav, post_process=args.post_process)
                texts.append(payload.get("rawText") or payload.get("text", ""))
            stable = len(set(texts)) == 1
            match = texts[0] == archived_raw
            flag = "✓" if match else "✗"
            stable_flag = "" if stable else " (unstable across repeats)"
            print(f"  {model}: {texts[0]!r} {flag}{stable_flag}")
            if not match:
                any_mismatch = True
        print()

    if any_mismatch:
        print(
            "Note: archived raw_text may include decoder steering not replayed by benchmark-transcribe."
        )
        return 2
    print("All replays matched archived raw_text.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
