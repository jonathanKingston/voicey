#!/usr/bin/env python3
"""Sweep steering cap knobs on local Session Archive clips (macOS + Rust runtime).

Rebuilds decoder context from archived screen snapshots, transcribes with steering via
voicey-supervisor, and scores against an audio-only baseline. Writes detailed JSON to
``--out`` (gitignored by default under benchmark-results/). Never commit that output or
user transcripts.

Requires: make build build-rust, downloaded Qwen model, Session Archive on disk.
"""

from __future__ import annotations

import argparse
import itertools
import json
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path

from voicey_jsonl_worker import JsonlWorker, new_request_id

REPO_ROOT = Path(__file__).resolve().parents[1]

DEFAULT_SCREEN_TERMS = (0, 4, 8, 16, 24, 32)
DEFAULT_MAX_TERMS = (16, 32, 48, 60)
DEFAULT_MAX_CONTEXT_CHARS = (128, 256, 512, 1024, 2000)

# Session Archive clips used as fixed steering-eval cases (local WAV; never commit audio).
# Keys are utterance id prefixes. ``reference_phrase`` is scored with normalized edit distance.
STEERING_EVAL_BY_ID_PREFIX: dict[str, dict] = {
    "d6a1c354": {
        "role": "swift_filename_bias",
        "reference_phrase": "incremental transcription coordinator dot swift",
        "manual_glossary": "IncrementalTranscriptionCoordinator.swift",
        "manual_glossary_enabled": True,
        "screen_context_enabled": False,
    },
}


def default_archive_root() -> Path:
    return Path.home() / "Library/Application Support/Voicey/SessionArchive"


def resolve_worker(name: str) -> Path:
    suffix = name.removeprefix("voicey-").replace("-", "_").upper()
    env_key = f"VOICEY_{suffix}_WORKER"
    override = os.environ.get(env_key)
    if override:
        candidate = Path(override)
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate
        raise SystemExit(f"{env_key} is not an executable file: {candidate}")

    for base in (
        REPO_ROOT / "Voicey.app/Contents/MacOS",
        REPO_ROOT / ".build/debug",
        REPO_ROOT / "target/debug",
    ):
        candidate = base / name
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate
    raise SystemExit(f"worker not found: {name} (run make build-rust)")


def resolve_voicey() -> Path:
    for candidate in (
        REPO_ROOT / "Voicey.app/Contents/MacOS/Voicey",
        REPO_ROOT / ".build/debug/Voicey",
    ):
        if candidate.is_file():
            return candidate
    raise SystemExit("Voicey binary not found (run make dev-restart or swift build)")


def worker_env(voicey: Path) -> dict[str, str]:
    env = os.environ.copy()
    env.setdefault("VOICEY_INFER_WORKER", str(voicey))
    for key, worker in (
        ("VOICEY_CAPTURE_WORKER", "voicey-capture"),
        ("VOICEY_TEXT_WORKER", "voicey-text"),
        ("VOICEY_FETCH_WORKER", "voicey-fetch"),
    ):
        env.setdefault(key, str(resolve_worker(worker)))
    return env


def parse_int_list(raw: str) -> tuple[int, ...]:
    values = tuple(int(part.strip()) for part in raw.split(",") if part.strip())
    if not values:
        raise argparse.ArgumentTypeError("expected comma-separated integers")
    return values


def normalized_tokens(text: str) -> list[str]:
    return [token.lower() for token in re.findall(r"[a-z0-9]+", text.lower())]


def normalized_levenshtein(a: str, b: str) -> float:
    if a == b:
        return 0.0
    if not a or not b:
        return 1.0
    rows = len(b) + 1
    cols = len(a) + 1
    dist = [[0] * cols for _ in range(rows)]
    for i in range(rows):
        dist[i][0] = i
    for j in range(cols):
        dist[0][j] = j
    for i, bc in enumerate(b, start=1):
        for j, ac in enumerate(a, start=1):
            cost = 0 if ac == bc else 1
            dist[i][j] = min(
                dist[i - 1][j] + 1,
                dist[i][j - 1] + 1,
                dist[i - 1][j - 1] + cost,
            )
    return dist[-1][-1] / max(len(a), len(b))


def steering_overlap_fraction(raw_text: str, steering_terms: list[str]) -> float:
    tokens = normalized_tokens(raw_text)
    if not tokens:
        return 0.0
    keys = {
        re.sub(r"[^a-z0-9]", "", term.lower())
        for term in steering_terms
        if term.strip()
    }
    keys.discard("")
    if not keys:
        return 0.0
    hits = sum(1 for token in tokens if token in keys)
    return hits / len(tokens)


@dataclass(frozen=True)
class CapConfig:
    max_screen_terms: int
    max_terms: int
    max_context_chars: int

    def key(self) -> str:
        return f"s{self.max_screen_terms}_t{self.max_terms}_c{self.max_context_chars}"


def cap_grid(
    screen_terms: tuple[int, ...],
    max_terms: tuple[int, ...],
    max_context_chars: tuple[int, ...],
) -> list[CapConfig]:
    configs: list[CapConfig] = []
    for s, t, c in itertools.product(screen_terms, max_terms, max_context_chars):
        if s > t:
            continue
        configs.append(CapConfig(s, t, c))
    return configs


def steering_eval_profile(utterance_id: str) -> dict | None:
    for prefix, profile in STEERING_EVAL_BY_ID_PREFIX.items():
        if utterance_id.startswith(prefix):
            return profile
    return None


def reference_token_recall(raw_text: str, reference_phrase: str) -> float:
    ref_tokens = normalized_tokens(reference_phrase)
    if not ref_tokens:
        return 1.0
    out_tokens = set(normalized_tokens(raw_text))
    return sum(1 for token in ref_tokens if token in out_tokens) / len(ref_tokens)


def reference_token_miss(raw_text: str, reference_phrase: str) -> float:
    return 1.0 - reference_token_recall(raw_text, reference_phrase)


def phrase_symbol_hits(raw_text: str) -> dict[str, bool]:
    lower = raw_text.lower()
    return {
        "incremental": "incremental" in lower,
        "coordinator": "coordinator" in lower,
        "swift": "swift" in lower,
        "dotted_swift_filename": "coordinator.swift" in lower.replace(" ", "")
            or "coordinator dot swift" in lower,
    }


def build_steering(
    text_worker: JsonlWorker,
    config: CapConfig,
    *,
    manual_glossary_enabled: bool,
    manual_glossary: str,
    screen_context_enabled: bool,
    snapshot: dict | None,
) -> dict:
    payload: dict = {
        "type": "build_steering_context",
        "manual_glossary_enabled": manual_glossary_enabled,
        "manual_glossary": manual_glossary,
        "screen_context_enabled": screen_context_enabled,
        "max_terms": config.max_terms,
        "max_screen_terms": config.max_screen_terms,
        "max_context_character_count": config.max_context_chars,
    }
    if screen_context_enabled and snapshot is not None:
        payload["snapshot"] = snapshot
    response = text_worker.request(payload)
    if response.get("type") != "steering_context_result" or not response.get("ok"):
        raise RuntimeError(f"build_steering_context failed: {response}")
    return response


def load_wav_pcm(capture: JsonlWorker, wav_path: Path) -> tuple[str, int]:
    response = capture.request(
        {
            "type": "load_wav_file",
            "path": str(wav_path),
        }
    )
    if response.get("type") != "capture_fixture_result" or not response.get("ok"):
        raise RuntimeError(f"load_wav_file failed: {response}")
    shm = response.get("shm_name")
    count = response.get("sample_count")
    if not shm or not count:
        raise RuntimeError(f"load_wav_file missing shm: {response}")
    return str(shm), int(count)


def transcribe(
    supervisor: JsonlWorker,
    *,
    model: str,
    shm_name: str,
    sample_count: int,
    decoder_context: str | None,
    language: str | None,
) -> str:
    payload: dict = {
        "type": "transcribe",
        "model_id": model,
        "sample_rate": 16_000,
        "shm_name": shm_name,
        "sample_count": sample_count,
        "sample_offset": 0,
    }
    if decoder_context:
        payload["decoder_context"] = decoder_context
    if language:
        payload["language"] = language
    response = supervisor.request(payload)
    if response.get("type") != "transcribe_result" or not response.get("ok"):
        raise RuntimeError(f"transcribe failed: {response}")
    return (response.get("raw_text") or "").strip()


def summarize_clip(rows: list[dict], *, eval_profile: dict | None) -> dict | None:
    if not rows:
        return None
    if eval_profile:
        best = min(
            rows,
            key=lambda row: (
                row["reference_token_miss"],
                row["baseline_distance"],
                row["context_chars"],
            ),
        )
        baseline_best = min(rows, key=lambda row: row["baseline_reference_token_miss"])
        return {
            "recommended": best["config"],
            "recommended_reference_token_miss": best["reference_token_miss"],
            "recommended_reference_token_recall": best["reference_token_recall"],
            "recommended_baseline_distance": best["baseline_distance"],
            "best_reference_without_steering": baseline_best["baseline_reference_token_miss"],
            "recommended_symbol_hits": best.get("symbol_hits"),
            "recommended_steering_overlap": best["steering_overlap"],
        }

    baseline = min(rows, key=lambda row: (row["baseline_distance"], row["context_chars"]))
    low_overlap = [row for row in rows if row["steering_overlap"] <= 0.35]
    pick_from = low_overlap if low_overlap else rows
    best = min(
        pick_from,
        key=lambda row: (
            row["baseline_distance"],
            row["context_chars"],
            row["term_count"],
        ),
    )
    return {
        "recommended": best["config"],
        "recommended_baseline_distance": best["baseline_distance"],
        "recommended_steering_overlap": best["steering_overlap"],
        "smallest_context_matching_baseline": baseline["config"],
    }


def aggregate_recommendation(report: dict) -> dict | None:
    clips = report.get("clips") or []
    if not clips:
        return None
    config_keys = [json.dumps(c, sort_keys=True) for c in report.get("configs", [])]
    scores: dict[str, dict] = {}
    for clip in clips:
        eval_profile = clip.get("eval_profile")
        for row in clip.get("results") or []:
            key = json.dumps(row["config"], sort_keys=True)
            bucket = scores.setdefault(
                key,
                {"config": row["config"], "soup_d": [], "ref_d": []},
            )
            if eval_profile:
                bucket["ref_d"].append(row["reference_token_miss"])
            else:
                bucket["soup_d"].append(row["baseline_distance"])

    def combined(entry: dict) -> tuple:
        soup = sum(entry["soup_d"]) / len(entry["soup_d"]) if entry["soup_d"] else 0.0
        ref = sum(entry["ref_d"]) / len(entry["ref_d"]) if entry["ref_d"] else 0.0
        return (ref, soup, entry["config"].get("max_context_chars", 0))

    best = min(scores.values(), key=combined)
    soup_mean = (
        sum(best["soup_d"]) / len(best["soup_d"]) if best["soup_d"] else None
    )
    ref_mean = sum(best["ref_d"]) / len(best["ref_d"]) if best["ref_d"] else None
    return {
        "config": best["config"],
        "mean_soup_baseline_distance": soup_mean,
        "mean_eval_reference_distance": ref_mean,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive-root", type=Path, default=default_archive_root())
    parser.add_argument("--model", default="qwen3-asr-1.7b-bf16")
    parser.add_argument("--language", default=None)
    parser.add_argument("--clip-id", default=None, help="Optional utterance id prefix filter")
    parser.add_argument("--max-clips", type=int, default=0, help="0 = all")
    parser.add_argument("--screen-terms", type=parse_int_list, default=None)
    parser.add_argument("--max-terms", type=parse_int_list, default=None)
    parser.add_argument("--max-context-chars", type=parse_int_list, default=None)
    parser.add_argument(
        "--out",
        type=Path,
        default=REPO_ROOT / "benchmark-results" / "steering-cap-sweep.json",
    )
    parser.add_argument(
        "--print-transcripts",
        action="store_true",
        help="Include raw transcripts in stdout (local only; do not commit logs)",
    )
    parser.add_argument(
        "--include-steering-eval",
        action="store_true",
        help="Always include built-in steering-eval archive clips (e.g. swift filename)",
    )
    parser.add_argument(
        "--soup-clip-prefixes",
        default="433f5711,375cdff3,4222e817",
        help="Comma-separated archive id prefixes for IDE/soup clips (screen steering)",
    )
    args = parser.parse_args()

    index_path = args.archive_root / "index.jsonl"
    if not index_path.is_file():
        print(f"no index at {index_path}", file=sys.stderr)
        return 1

    voicey = resolve_voicey()
    env = worker_env(voicey)
    supervisor_path = resolve_worker("voicey-supervisor")
    capture_path = resolve_worker("voicey-capture")
    text_path = resolve_worker("voicey-text")

    configs = cap_grid(
        args.screen_terms or DEFAULT_SCREEN_TERMS,
        args.max_terms or DEFAULT_MAX_TERMS,
        args.max_context_chars or DEFAULT_MAX_CONTEXT_CHARS,
    )
    records = [
        json.loads(line)
        for line in index_path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    eval_records = [
        rec
        for rec in records
        if steering_eval_profile(rec.get("id", "")) is not None
    ]
    soup_prefixes = tuple(p.strip() for p in args.soup_clip_prefixes.split(",") if p.strip())
    if args.clip_id:
        records = [rec for rec in records if rec.get("id", "").startswith(args.clip_id)]
    elif soup_prefixes and not args.max_clips:
        records = [
            rec
            for rec in records
            if any(rec.get("id", "").startswith(prefix) for prefix in soup_prefixes)
        ]
    if args.include_steering_eval:
        seen = {rec["id"] for rec in records}
        for rec in eval_records:
            if rec["id"] not in seen:
                records.append(rec)
                seen.add(rec["id"])
    if args.max_clips > 0:
        records = records[: args.max_clips]

    if not records:
        print("no archive records matched", file=sys.stderr)
        return 1

    print(
        f"Sweep: {len(records)} clip(s), {len(configs)} cap configs, model={args.model}",
        file=sys.stderr,
    )

    supervisor = JsonlWorker(str(supervisor_path), env=env)
    capture = JsonlWorker(str(capture_path), env=env)
    text_worker = JsonlWorker(str(text_path))

    try:
        prewarm = supervisor.request(
            {
                "type": "prewarm_infer",
                "model_id": args.model,
            }
        )
        if prewarm.get("type") not in {"infer_ready", "ready"}:
            raise RuntimeError(f"prewarm_infer failed: {prewarm}")

        report: dict = {
            "model": args.model,
            "archive_root": str(args.archive_root),
            "configs": [config.__dict__ for config in configs],
            "clips": [],
        }

        for rec in records:
            uid = rec["id"].replace("-", "")
            snap_path = args.archive_root / "snapshots" / f"{uid}.json"
            wav_path = args.archive_root / rec["audio_path"]
            if not wav_path.is_file():
                print(f"skip {rec['id'][:8]} missing wav", file=sys.stderr)
                continue

            eval_profile = steering_eval_profile(rec.get("id", ""))
            snapshot = None
            if snap_path.is_file():
                snapshot = json.loads(snap_path.read_text(encoding="utf-8"))

            shm_name, sample_count = load_wav_pcm(capture, wav_path)
            language = rec.get("language_id") or args.language

            baseline_raw = transcribe(
                supervisor,
                model=args.model,
                shm_name=shm_name,
                sample_count=sample_count,
                decoder_context=None,
                language=language,
            )

            clip_rows: list[dict] = []
            role = eval_profile["role"] if eval_profile else "screen_soup"
            print(
                f"\n— {rec['id'][:8]} [{role}] baseline (no steering): {baseline_raw!r}",
                file=sys.stderr,
            )
            ref_phrase = (eval_profile or {}).get("reference_phrase")
            baseline_ref_miss = (
                reference_token_miss(baseline_raw, ref_phrase) if ref_phrase else None
            )
            if ref_phrase:
                print(
                    f"  baseline reference token miss={baseline_ref_miss:.3f} "
                    f"recall={reference_token_recall(baseline_raw, ref_phrase):.2f} "
                    f"hits={phrase_symbol_hits(baseline_raw)}",
                    file=sys.stderr,
                )

            for config in configs:
                if eval_profile:
                    steering = build_steering(
                        text_worker,
                        config,
                        manual_glossary_enabled=bool(
                            eval_profile.get("manual_glossary_enabled")
                        ),
                        manual_glossary=str(eval_profile.get("manual_glossary") or ""),
                        screen_context_enabled=bool(
                            eval_profile.get("screen_context_enabled")
                        ),
                        snapshot=snapshot,
                    )
                else:
                    steering = build_steering(
                        text_worker,
                        config,
                        manual_glossary_enabled=bool(rec.get("glossary_enabled")),
                        manual_glossary="",
                        screen_context_enabled=True,
                        snapshot=snapshot,
                    )
                terms = steering.get("terms") or []
                decoder_context = steering.get("decoder_context")
                ctx_chars = len(decoder_context or "")

                steered_raw = transcribe(
                    supervisor,
                    model=args.model,
                    shm_name=shm_name,
                    sample_count=sample_count,
                    decoder_context=decoder_context,
                    language=language,
                )

                row = {
                    "config": config.__dict__,
                    "term_count": len(terms),
                    "context_chars": ctx_chars,
                    "baseline_distance": normalized_levenshtein(steered_raw, baseline_raw),
                    "steering_overlap": steering_overlap_fraction(steered_raw, terms),
                    "raw_text": steered_raw,
                }
                if ref_phrase:
                    row["reference_token_recall"] = reference_token_recall(
                        steered_raw, ref_phrase
                    )
                    row["reference_token_miss"] = reference_token_miss(
                        steered_raw, ref_phrase
                    )
                    row["baseline_reference_token_miss"] = baseline_ref_miss
                    row["symbol_hits"] = phrase_symbol_hits(steered_raw)
                clip_rows.append(row)

                if args.print_transcripts:
                    extra = ""
                    if ref_phrase:
                        extra = (
                            f" ref_miss={row['reference_token_miss']:.3f}"
                            f" hits={row['symbol_hits']}"
                        )
                    print(
                        f"  {config.key()} terms={len(terms)} ctx={ctx_chars} "
                        f"d={row['baseline_distance']:.3f} overlap={row['steering_overlap']:.2f}"
                        f"{extra} {steered_raw!r}",
                        file=sys.stderr,
                    )

            summary = summarize_clip(clip_rows, eval_profile=eval_profile)
            report["clips"].append(
                {
                    "id": rec["id"],
                    "role": role,
                    "eval_profile": eval_profile,
                    "audio_seconds": rec.get("audio_seconds"),
                    "baseline_raw_text": baseline_raw,
                    "reference_phrase": ref_phrase,
                    "summary": summary,
                    "results": clip_rows,
                }
            )

            if summary:
                if eval_profile:
                    print(
                        f"  recommend {summary['recommended']} "
                        f"(ref_miss={summary['recommended_reference_token_miss']:.3f}, "
                        f"recall={summary['recommended_reference_token_recall']:.2f}, "
                        f"baseline_d={summary['recommended_baseline_distance']:.3f}, "
                        f"no-steer ref_miss={summary['best_reference_without_steering']:.3f})",
                        file=sys.stderr,
                    )
                else:
                    print(
                        f"  recommend {summary['recommended']} "
                        f"(d={summary['recommended_baseline_distance']:.3f}, "
                        f"overlap={summary['recommended_steering_overlap']:.2f})",
                        file=sys.stderr,
                    )

        report["aggregate"] = aggregate_recommendation(report)
        if report.get("aggregate"):
            agg = report["aggregate"]
            print(
                f"\nAggregate (min mean eval ref_d, then soup baseline_d): {agg['config']} "
                f"eval_ref_miss={agg.get('mean_eval_reference_distance')} "
                f"soup_d={agg.get('mean_soup_baseline_distance')}",
                file=sys.stderr,
            )

        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps(report, indent=2), encoding="utf-8")
        print(f"\nWrote {args.out} (gitignored — do not commit)", file=sys.stderr)
    finally:
        text_worker.close()
        capture.close()
        supervisor.close()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
