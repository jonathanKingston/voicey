#!/usr/bin/env python3
"""Replay Session Archive utterances and compare to stored transcripts.

Rebuilds steering from archived glossary/screen flags + snapshot, transcribes with
voicey-supervisor, optionally runs voicey-text post-process. Use to validate steering
sanitizer defaults after cap changes.

Requires: make build build-rust, downloaded Qwen model, local Session Archive WAVs.
Output under benchmark-results/ (gitignored). Never commit audio or transcripts.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

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

DEFAULT_CAP = CapConfig(
    max_screen_terms=8,
    max_terms=32,
    max_context_chars=256,
)


def default_archive_root() -> Path:
    return Path.home() / "Library/Application Support/Voicey/SessionArchive"


def load_records(archive_root: Path, *, clip_id: str | None, max_clips: int) -> list[dict]:
    index_path = archive_root / "index.jsonl"
    if not index_path.is_file():
        raise SystemExit(f"no Session Archive index at {index_path}")

    records = [
        json.loads(line)
        for line in index_path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    if clip_id:
        records = [rec for rec in records if rec.get("id", "").startswith(clip_id)]
    if max_clips > 0:
        records = records[:max_clips]
    if not records:
        raise SystemExit("no archive records matched filters")
    return records


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


def replay_record(
    *,
    rec: dict,
    archive_root: Path,
    supervisor: JsonlWorker,
    capture: JsonlWorker,
    text_worker: JsonlWorker,
    model: str,
    cap: CapConfig,
    run_postprocess: bool,
) -> dict:
    uid = rec["id"].replace("-", "")
    wav_path = archive_root / rec["audio_path"]
    if not wav_path.is_file():
        return {"id": rec["id"], "status": "missing_wav", "audio_path": str(wav_path)}

    snap_path = archive_root / "snapshots" / f"{uid}.json"
    snapshot = json.loads(snap_path.read_text(encoding="utf-8")) if snap_path.is_file() else None

    shm_name, sample_count = load_wav_pcm(capture, wav_path)
    language = rec.get("language_id")

    raw_none = transcribe(
        supervisor,
        model=model,
        shm_name=shm_name,
        sample_count=sample_count,
        decoder_context=None,
        language=language,
    )

    steering = build_steering(
        text_worker,
        cap,
        manual_glossary_enabled=bool(rec.get("glossary_enabled")),
        manual_glossary="",
        screen_context_enabled=bool(rec.get("screen_context_enabled")),
        snapshot=snapshot,
    )
    terms = steering.get("terms") or []
    decoder_context = steering.get("decoder_context")
    raw_steered = transcribe(
        supervisor,
        model=model,
        shm_name=shm_name,
        sample_count=sample_count,
        decoder_context=decoder_context,
        language=language,
    )

    stored_raw = (rec.get("raw_text") or "").strip()
    stored_processed = (rec.get("processed_text") or "").strip()
    replay_processed = raw_steered
    if run_postprocess:
        replay_processed = postprocess(
            text_worker,
            text=raw_steered,
            decoder_context=decoder_context,
            steering_terms=terms,
        )

    reference = stored_processed or stored_raw
    return {
        "id": rec["id"],
        "status": "ok",
        "failure_class": rec.get("failure_class"),
        "audio_seconds": rec.get("audio_seconds"),
        "stored_raw_text": stored_raw,
        "stored_processed_text": stored_processed,
        "replay_raw_none": raw_none,
        "replay_raw_steered": raw_steered,
        "replay_processed": replay_processed,
        "steering_term_count": len(terms),
        "decoder_context_chars": len(decoder_context or ""),
        "raw_none_distance": normalized_levenshtein(raw_none, stored_raw),
        "raw_steered_distance": normalized_levenshtein(raw_steered, stored_raw),
        "processed_distance": normalized_levenshtein(replay_processed, stored_processed),
        "stored_token_recall": reference_token_recall(stored_processed, reference),
        "replay_token_recall": reference_token_recall(replay_processed, reference),
    }


def write_summary_markdown(path: Path, rows: list[dict]) -> None:
    lines = [
        "# Session archive replay",
        "",
        "| id | status | raw_none d | raw_steered d | proc d | steer terms | ctx chars |",
        "| --- | --- | ---: | ---: | ---: | ---: | ---: |",
    ]
    for row in rows:
        if row.get("status") != "ok":
            lines.append(f"| {row.get('id', '?')[:8]} | {row.get('status')} | — | — | — | — | — |")
            continue
        lines.append(
            "| "
            + " | ".join(
                [
                    row["id"][:8],
                    "ok",
                    f"{row['raw_none_distance']:.3f}",
                    f"{row['raw_steered_distance']:.3f}",
                    f"{row['processed_distance']:.3f}",
                    str(row["steering_term_count"]),
                    str(row["decoder_context_chars"]),
                ]
            )
            + " |"
        )
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive-root", type=Path, default=default_archive_root())
    parser.add_argument("--model", default="qwen3-asr-1.7b-bf16")
    parser.add_argument("--clip-id", default=None, help="Optional utterance id prefix filter")
    parser.add_argument("--max-clips", type=int, default=0, help="0 = all matched clips")
    parser.add_argument("--post-process", action="store_true", help="Run voicey-text post-process")
    parser.add_argument(
        "--out",
        type=Path,
        default=REPO_ROOT / "benchmark-results" / "session-archive-replay.json",
    )
    args = parser.parse_args()

    records = load_records(args.archive_root, clip_id=args.clip_id, max_clips=args.max_clips)
    voicey = resolve_voicey()
    env = worker_env(voicey)
    supervisor = JsonlWorker(str(resolve_worker("voicey-supervisor")), env=env)
    capture = JsonlWorker(str(resolve_worker("voicey-capture")), env=env)
    text_worker = JsonlWorker(str(resolve_worker("voicey-text")))

    rows: list[dict] = []
    try:
        prewarm = supervisor.request({"type": "prewarm_infer", "model_id": args.model})
        if prewarm.get("type") not in {"infer_ready", "ready"}:
            raise RuntimeError(f"prewarm_infer failed: {prewarm}")

        for rec in records:
            row = replay_record(
                rec=rec,
                archive_root=args.archive_root,
                supervisor=supervisor,
                capture=capture,
                text_worker=text_worker,
                model=args.model,
                cap=DEFAULT_CAP,
                run_postprocess=args.post_process,
            )
            rows.append(row)
            if row.get("status") == "ok":
                print(
                    f"{row['id'][:8]} raw_none_d={row['raw_none_distance']:.3f} "
                    f"steered_d={row['raw_steered_distance']:.3f} "
                    f"proc_d={row['processed_distance']:.3f}",
                    file=sys.stderr,
                )
            else:
                print(f"{row.get('id', '?')[:8]} {row.get('status')}", file=sys.stderr)
    finally:
        text_worker.close()
        capture.close()
        supervisor.close()

    payload = {
        "model": args.model,
        "archive_root": str(args.archive_root),
        "post_process": args.post_process,
        "clips": rows,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    write_summary_markdown(args.out.with_suffix(".md"), rows)
    print(f"Wrote {args.out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
