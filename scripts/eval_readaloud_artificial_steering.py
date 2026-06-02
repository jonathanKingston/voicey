#!/usr/bin/env python3
"""Replay Session Archive read-aloud WAVs with artificial steering (glossary + snapshot).

One recording per script line is enough: live glossary/screen settings are not required.
Baseline = transcribe with no decoder context; steered modes inject glossary/caps/snapshot
from this script only. Scripted reference lines are ground truth for scoring.

Corpus: Benchmarks/readaloud_steering_corpus.json (recording guide: ReadAloudSteeringRecording.md).
Writes JSON under benchmark-results/ (gitignored). Never commit output or user audio.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

from readaloud_corpus_lib import (
    blended_glossary,
    clips_from_manifest,
    load_corpus_manifest,
    pending_clips,
)
from sweep_steering_caps import (
    CapConfig,
    build_steering,
    load_wav_pcm,
    normalized_levenshtein,
    reference_token_recall,
    resolve_voicey,
    resolve_worker,
    transcribe,
    worker_env,
)
from voicey_jsonl_worker import JsonlWorker

DEFAULT_CAP = CapConfig(max_screen_terms=16, max_terms=48, max_context_chars=512)

FILENAME_RE = re.compile(r"IncrementalTranscriptionCoordinator\.swift", re.I)
CAMEL_RE = re.compile(r"\bIncrementalTranscriptionCoordinator\b")


def default_archive_root() -> Path:
    return Path.home() / "Library/Application Support/Voicey/SessionArchive"


def load_record(archive_root: Path, id_prefix: str) -> dict:
    for line in (archive_root / "index.jsonl").read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        rec = json.loads(line)
        if rec.get("id", "").startswith(id_prefix):
            return rec
    raise SystemExit(f"no archive row for prefix {id_prefix}")


def score_transcript(raw: str, reference: str, *, expect_swift: bool, expect_token: str | None) -> dict:
    has_token = None
    if expect_token:
        has_token = expect_token.lower() in raw.lower()
    return {
        "reference_levenshtein": normalized_levenshtein(raw, reference),
        "reference_token_recall": reference_token_recall(raw, reference),
        "has_swift_filename": bool(FILENAME_RE.search(raw)),
        "has_camel_case": bool(CAMEL_RE.search(raw)),
        "expect_swift_met": bool(FILENAME_RE.search(raw)) if expect_swift else None,
        "expect_glossary_token": expect_token,
        "expect_glossary_token_met": has_token,
    }


def run_eval(
    *,
    archive_root: Path,
    model: str,
    glossary: str,
    clips: tuple,
    cap: CapConfig = DEFAULT_CAP,
) -> dict:
    voicey = resolve_voicey()
    env = worker_env(voicey)
    supervisor = JsonlWorker(str(resolve_worker("voicey-supervisor")), env=env)
    capture = JsonlWorker(str(resolve_worker("voicey-capture")), env=env)
    text_worker = JsonlWorker(str(resolve_worker("voicey-text")))

    report: dict = {
        "model": model,
        "glossary": glossary,
        "cap": {"max_screen_terms": cap.max_screen_terms, "max_terms": cap.max_terms, "max_context_chars": cap.max_context_chars},
        "clips": [],
    }

    try:
        prewarm = supervisor.request({"type": "prewarm_infer", "model_id": model})
        if prewarm.get("type") not in {"infer_ready", "ready"}:
            raise RuntimeError(f"prewarm failed: {prewarm}")

        for clip in clips:
            rec = load_record(archive_root, clip.id_prefix)
            uid = rec["id"].replace("-", "")
            wav = archive_root / rec["audio_path"]
            snap_path = archive_root / "snapshots" / f"{uid}.json"
            snapshot = json.loads(snap_path.read_text()) if snap_path.is_file() else None

            shm, count = load_wav_pcm(capture, wav)
            modes: list[tuple[str, str | None]] = []

            raw_none = transcribe(
                supervisor,
                model=model,
                shm_name=shm,
                sample_count=count,
                decoder_context=None,
                language=None,
            )
            modes.append(("none", raw_none))

            gloss_ctx = build_steering(
                text_worker,
                CapConfig(0, cap.max_terms, cap.max_context_chars),
                manual_glossary_enabled=True,
                manual_glossary=glossary,
                screen_context_enabled=False,
                snapshot=None,
            ).get("decoder_context")
            raw_g = transcribe(
                supervisor,
                model=model,
                shm_name=shm,
                sample_count=count,
                decoder_context=gloss_ctx,
                language=None,
            )
            modes.append(("glossary_artificial", raw_g))

            if snapshot:
                combo_ctx = build_steering(
                    text_worker,
                    cap,
                    manual_glossary_enabled=True,
                    manual_glossary=glossary,
                    screen_context_enabled=True,
                    snapshot=snapshot,
                ).get("decoder_context")
                raw_gs = transcribe(
                    supervisor,
                    model=model,
                    shm_name=shm,
                    sample_count=count,
                    decoder_context=combo_ctx,
                    language=None,
                )
                modes.append(("glossary_and_screen_artificial", raw_gs))

            entry = {
                "id": rec["id"],
                "script": clip.script,
                "category": clip.category,
                "reference": clip.reference,
                "expect_coordinator_swift": clip.expect_coordinator_swift,
                "live_glossary_enabled": rec.get("glossary_enabled"),
                "live_screen_context_enabled": rec.get("screen_context_enabled"),
                "live_steering_terms": rec.get("steering_terms"),
                "live_raw_text": rec.get("raw_text"),
                "modes": {},
            }
            for mode_name, raw in modes:
                entry["modes"][mode_name] = {
                    "raw_text": raw,
                    **score_transcript(
                        raw,
                        clip.reference,
                        expect_swift=clip.expect_coordinator_swift,
                        expect_token=clip.expect_glossary_token,
                    ),
                }
            report["clips"].append(entry)
    finally:
        text_worker.close()
        capture.close()
        supervisor.close()

    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive-root", type=Path, default=default_archive_root())
    parser.add_argument("--model", default="qwen3-asr-1.7b-bf16")
    parser.add_argument("--corpus", type=Path, default=REPO_ROOT / "Benchmarks" / "readaloud_steering_corpus.json")
    parser.add_argument("--glossary", default=None, help="Override blended glossary from corpus manifest")
    parser.add_argument("--out", type=Path, default=REPO_ROOT / "benchmark-results" / "readaloud-artificial-steering.json")
    parser.add_argument("--id-prefix", action="append", dest="id_prefixes", help="Limit to clip id prefix (repeatable)")
    args = parser.parse_args()

    manifest = load_corpus_manifest(args.corpus)
    glossary = args.glossary or blended_glossary(manifest)
    clips = clips_from_manifest(manifest, require_id=True)

    if args.id_prefixes:
        prefixes = set(args.id_prefixes)
        clips = tuple(c for c in clips if c.id_prefix in prefixes)

    pending = pending_clips(manifest)
    if pending:
        print(
            f"Note: {len(pending)} corpus lines not recorded yet ({', '.join(r['script'] for r in pending[:5])}…). "
            f"See Benchmarks/ReadAloudSteeringRecording.md",
            file=sys.stderr,
        )

    report = run_eval(
        archive_root=args.archive_root,
        model=args.model,
        glossary=glossary,
        clips=clips,
    )

    for clip in report["clips"]:
        modes = clip["modes"]
        best = min(modes.items(), key=lambda item: item[1]["reference_levenshtein"])
        print(
            f"{clip['id'][:8]} {clip['script']} [{clip['category']}]: live={clip['live_raw_text']!r}",
            file=sys.stderr,
        )
        print(f"  best vs script: {best[0]} (d={best[1]['reference_levenshtein']:.3f})", file=sys.stderr)
        tok = modes.get("glossary_artificial", {}).get("expect_glossary_token_met")
        if tok is not None:
            print(f"  glossary token hit: {tok}", file=sys.stderr)

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(f"\nWrote {args.out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
