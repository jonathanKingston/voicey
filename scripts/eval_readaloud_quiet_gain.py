#!/usr/bin/env python3
"""Compare read-aloud ASR at full level vs ffmpeg-attenuated clips (validates quiet gain path).

Requires: built Voicey + Rust workers, ffmpeg, read-aloud artifact bundle.
Writes benchmark-results/readaloud-quiet-gain-validation.json
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import benchmark_common_voice as bcv
from readaloud_corpus_lib import clips_from_manifest, load_corpus_manifest
from sweep_steering_caps import load_wav_pcm, resolve_voicey, resolve_worker, transcribe, worker_env
from voicey_jsonl_worker import JsonlWorker

DEFAULT_ART = Path.home() / "Library/Application Support/Voicey/Artifacts/readaloud-corpus-v3"


def wer(ref: str, hyp: str) -> float:
    return bcv.compute_text_metrics(ref, hyp, False, False).wer


def attenuate_wav(source: Path, destination: Path, db: float) -> None:
    subprocess.run(
        [
            "ffmpeg",
            "-nostdin",
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-i",
            str(source),
            "-af",
            f"volume={db}dB",
            "-ar",
            "16000",
            "-ac",
            "1",
            str(destination),
        ],
        check=True,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive-root", type=Path, default=DEFAULT_ART)
    parser.add_argument("--model", default="qwen3-asr-1.7b-bf16")
    parser.add_argument("--attenuation-db", type=float, default=-12.0)
    parser.add_argument(
        "--out",
        type=Path,
        default=REPO_ROOT / "benchmark-results/readaloud-quiet-gain-validation.json",
    )
    args = parser.parse_args()

    if not shutil.which("ffmpeg"):
        print("error: ffmpeg required", file=sys.stderr)
        return 1
    if not (args.archive_root / "index.jsonl").is_file():
        print(f"error: missing artifact bundle {args.archive_root}", file=sys.stderr)
        return 1

    manifest = load_corpus_manifest(REPO_ROOT / "Benchmarks/readaloud_steering_corpus.json")
    clips = clips_from_manifest(manifest, require_id=True)

    voicey = resolve_voicey()
    env = worker_env(voicey)
    capture = JsonlWorker(str(resolve_worker("voicey-capture")), env=env)
    supervisor = JsonlWorker(str(resolve_worker("voicey-supervisor")), env=env)

    rows: list[dict] = []
    try:
        with tempfile.TemporaryDirectory(prefix="voicey-quiet-gain-") as tmp:
            tmp_path = Path(tmp)
            for clip in clips:
                prefix = clip.id_prefix
                rec = None
                for line in (args.archive_root / "index.jsonl").read_text().splitlines():
                    if not line.strip():
                        continue
                    row = json.loads(line)
                    if row.get("id", "").startswith(prefix):
                        rec = row
                        break
                if rec is None:
                    print(f"error: no archive row for {clip.script}", file=sys.stderr)
                    return 1
                wav = args.archive_root / rec["audio_path"]
                quiet_wav = tmp_path / f"{prefix}-quiet.wav"
                attenuate_wav(wav, quiet_wav, args.attenuation_db)

                for label, path in (("full", wav), ("quiet", quiet_wav)):
                    shm, count = load_wav_pcm(capture, path)
                    raw = transcribe(
                        supervisor,
                        model=args.model,
                        shm_name=shm,
                        sample_count=count,
                        decoder_context=None,
                        language=None,
                    )
                    rows.append(
                        {
                            "script": clip.script,
                            "category": clip.category,
                            "level": label,
                            "reference": clip.reference,
                            "raw_text": raw,
                            "wer": wer(clip.reference, raw),
                            "attenuation_db": 0.0 if label == "full" else args.attenuation_db,
                        }
                    )
                print(
                    f"{clip.script} full={rows[-2]['wer']:.3f} quiet={rows[-1]['wer']:.3f}",
                    file=sys.stderr,
                )
    finally:
        capture.close()
        supervisor.close()

    full = [r for r in rows if r["level"] == "full"]
    quiet = [r for r in rows if r["level"] == "quiet"]
    summary = {
        "model": args.model,
        "attenuation_db": args.attenuation_db,
        "mean_wer_full": sum(r["wer"] for r in full) / len(full),
        "mean_wer_quiet": sum(r["wer"] for r in quiet) / len(quiet),
        "quiet_wer_not_worse_than_full": sum(
            1 for f, q in zip(full, quiet) if q["wer"] <= f["wer"] + 0.001
        ),
        "clip_count": len(full),
    }
    payload = {"summary": summary, "clips": rows}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, indent=2))
    print(f"Wrote {args.out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
