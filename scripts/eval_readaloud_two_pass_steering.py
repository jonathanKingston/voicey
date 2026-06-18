#!/usr/bin/env python3
"""Compare Phase A steered replay vs two-pass adaptive steering on read-aloud clips.

Adaptive flow per clip:
  1. Probe transcribe (no decoder context, or glossary-only).
  2. Append probe text to snapshot ``query_text`` for BM25 reranking.
  3. Rebuild steering + transcribe full utterance again.

Output: benchmark-results/readaloud-two-pass-steering.json (or --out).
"""

from __future__ import annotations

import argparse
import copy
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

from eval_readaloud_artificial_steering import (
    default_archive_root,
    load_record,
    score_transcript,
)
from readaloud_corpus_lib import blended_glossary, clips_from_manifest, load_corpus_manifest
from sweep_steering_caps import (
    CapConfig,
    build_steering,
    load_wav_pcm,
    resolve_voicey,
    resolve_worker,
    steering_overlap_fraction,
    transcribe,
    worker_env,
)
from voicey_jsonl_worker import JsonlWorker

PHASE_A = CapConfig(max_screen_terms=8, max_terms=32, max_context_chars=256)


def adaptive_snapshot(snapshot: dict | None, probe_text: str) -> dict | None:
    if snapshot is None:
        return None
    merged = copy.deepcopy(snapshot)
    prior = (merged.get("query_text") or "").strip()
    probe = probe_text.strip()
    if not probe:
        return merged
    merged["query_text"] = f"{prior} {probe}".strip() if prior else probe
    return merged


def run_clip(
    *,
    archive_root: Path,
    clip,
    glossary: str,
    model: str,
    cap: CapConfig,
    probe: str,
    capture: JsonlWorker,
    supervisor: JsonlWorker,
    text_worker: JsonlWorker,
) -> dict:
    rec = load_record(archive_root, clip.id_prefix)
    uid = rec["id"].replace("-", "")
    wav = archive_root / rec["audio_path"]
    snap_path = archive_root / "snapshots" / f"{uid}.json"
    snapshot = json.loads(snap_path.read_text()) if snap_path.is_file() else None

    shm, count = load_wav_pcm(capture, wav)

    gloss_ctx = None
    if probe == "glossary":
        gloss_ctx = build_steering(
            text_worker,
            cap,
            manual_glossary_enabled=True,
            manual_glossary=glossary,
            screen_context_enabled=False,
            snapshot=None,
        ).get("decoder_context")

    probe_raw = transcribe(
        supervisor,
        model=model,
        shm_name=shm,
        sample_count=count,
        decoder_context=gloss_ctx,
        language=None,
    )

    static_steering = build_steering(
        text_worker,
        cap,
        manual_glossary_enabled=True,
        manual_glossary=glossary,
        screen_context_enabled=snapshot is not None,
        snapshot=snapshot,
    )
    static_ctx = static_steering.get("decoder_context")
    static_terms = static_steering.get("terms") or []
    static_raw = transcribe(
        supervisor,
        model=model,
        shm_name=shm,
        sample_count=count,
        decoder_context=static_ctx,
        language=None,
    )

    adaptive_snap = adaptive_snapshot(snapshot, probe_raw)
    adaptive_steering = build_steering(
        text_worker,
        cap,
        manual_glossary_enabled=True,
        manual_glossary=glossary,
        screen_context_enabled=adaptive_snap is not None,
        snapshot=adaptive_snap,
    )
    adaptive_ctx = adaptive_steering.get("decoder_context")
    adaptive_terms = adaptive_steering.get("terms") or []
    adaptive_raw = transcribe(
        supervisor,
        model=model,
        shm_name=shm,
        sample_count=count,
        decoder_context=adaptive_ctx,
        language=None,
    )

    def pack(raw: str, terms: list) -> dict:
        return {
            "raw_text": raw,
            **score_transcript(
                raw,
                clip.reference,
                expect_swift=clip.expect_coordinator_swift,
                expect_token=clip.expect_glossary_token,
            ),
            "steering_overlap": steering_overlap_fraction(raw, [str(t) for t in terms]),
        }

    return {
        "id": rec["id"],
        "script": clip.script,
        "category": clip.category,
        "has_snapshot": snapshot is not None,
        "probe_reference_levenshtein": score_transcript(
            probe_raw, clip.reference, expect_swift=clip.expect_coordinator_swift, expect_token=None
        )["reference_levenshtein"],
        "modes": {
            "phase_a_static": pack(static_raw, static_terms),
            "two_pass_adaptive": pack(adaptive_raw, adaptive_terms),
        },
        "steering_term_count_static": len(static_terms),
        "steering_term_count_adaptive": len(adaptive_terms),
        "steering_terms_changed": static_terms != adaptive_terms,
    }


def aggregate(report: dict) -> dict:
    clips = report.get("clips") or []
    if not clips:
        return {"clip_count": 0}

    def mean_key(mode: str, key: str) -> float:
        vals = [c["modes"][mode][key] for c in clips if mode in c.get("modes", {})]
        return sum(vals) / len(vals) if vals else 0.0

    wins_a = wins_s = ties = 0
    for c in clips:
        s = c["modes"]["phase_a_static"]["reference_levenshtein"]
        a = c["modes"]["two_pass_adaptive"]["reference_levenshtein"]
        if a < s - 1e-9:
            wins_a += 1
        elif s < a - 1e-9:
            wins_s += 1
        else:
            ties += 1

    return {
        "clip_count": len(clips),
        "clips_with_snapshot": sum(1 for c in clips if c.get("has_snapshot")),
        "mean_reference_levenshtein_static": mean_key("phase_a_static", "reference_levenshtein"),
        "mean_reference_levenshtein_adaptive": mean_key("two_pass_adaptive", "reference_levenshtein"),
        "mean_token_recall_static": mean_key("phase_a_static", "reference_token_recall"),
        "mean_token_recall_adaptive": mean_key("two_pass_adaptive", "reference_token_recall"),
        "adaptive_wins_on_reference_levenshtein": wins_a,
        "static_wins_on_reference_levenshtein": wins_s,
        "ties": ties,
        "steering_terms_changed_count": sum(1 for c in clips if c.get("steering_terms_changed")),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive-root", type=Path, default=None)
    parser.add_argument("--model", default="qwen3-asr-1.7b-bf16")
    parser.add_argument("--corpus", type=Path, default=REPO_ROOT / "Benchmarks/readaloud_steering_corpus.json")
    parser.add_argument("--glossary", default=None)
    parser.add_argument("--probe", choices=("none", "glossary"), default="none")
    parser.add_argument("--out", type=Path, default=REPO_ROOT / "benchmark-results/readaloud-two-pass-steering.json")
    args = parser.parse_args()

    archive_root = args.archive_root or default_archive_root()
    if args.archive_root is None:
        artifact = Path.home() / "Library/Application Support/Voicey/Artifacts/readaloud-corpus-v3"
        if (artifact / "index.jsonl").is_file():
            archive_root = artifact

    glossary = args.glossary or blended_glossary()
    manifest = load_corpus_manifest(args.corpus)
    clips = clips_from_manifest(manifest, require_id=True)

    voicey = resolve_voicey()
    env = worker_env(voicey)
    capture = JsonlWorker(str(resolve_worker("voicey-capture")), env=env)
    supervisor = JsonlWorker(str(resolve_worker("voicey-supervisor")), env=env)
    text_worker = JsonlWorker(str(resolve_worker("voicey-text")), env=env)

    report = {
        "model": args.model,
        "cap": {
            "max_screen_terms": PHASE_A.max_screen_terms,
            "max_terms": PHASE_A.max_terms,
            "max_context_chars": PHASE_A.max_context_chars,
        },
        "probe": args.probe,
        "archive_root": str(archive_root),
        "clips": [],
    }

    try:
        for clip in clips:
            print(f"two-pass {clip.script} …", file=sys.stderr, flush=True)
            report["clips"].append(
                run_clip(
                    archive_root=archive_root,
                    clip=clip,
                    glossary=glossary,
                    model=args.model,
                    cap=PHASE_A,
                    probe=args.probe,
                    capture=capture,
                    supervisor=supervisor,
                    text_worker=text_worker,
                )
            )
    finally:
        capture.close()
        supervisor.close()
        text_worker.close()

    report["aggregate"] = aggregate(report)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report["aggregate"], indent=2))
    print(f"Wrote {args.out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
