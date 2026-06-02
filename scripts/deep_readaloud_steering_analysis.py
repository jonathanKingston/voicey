#!/usr/bin/env python3
"""Deep read-aloud corpus analysis: baseline + cap sweeps with replay-injected steering.

Profiles per clip type (glossary / screen / combo), regurgitation and false-positive
flags, live archive metadata, aggregate cap recommendations. Output: benchmark-results/
(readaloud-deep-analysis.json). macOS + Rust runtime required.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import defaultdict
from dataclasses import asdict
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

from eval_readaloud_artificial_steering import (
    FILENAME_RE,
    default_archive_root,
    load_record,
    score_transcript,
)
from readaloud_corpus_lib import ReadAloudClip, blended_glossary, clips_from_manifest

READALOUD_CLIPS = clips_from_manifest()
DEFAULT_GLOSSARY = blended_glossary()
from sweep_steering_caps import (
    CapConfig,
    build_steering,
    cap_grid,
    load_wav_pcm,
    normalized_levenshtein,
    reference_token_recall,
    resolve_voicey,
    resolve_worker,
    steering_overlap_fraction,
    transcribe,
    worker_env,
)
from voicey_jsonl_worker import JsonlWorker

UT_FINISH_RE = re.compile(r"UtteranceTranscriptionFinish\.swift", re.I)
VOICEY_TEXT_RE = re.compile(r"voicey-text", re.I)

SCREEN_SWEEP = (0, 8, 16, 24)
TERM_SWEEP = (32, 48)
CHAR_SWEEP = (256, 512, 1024)

GLOSSARY_SCRIPTS = {"#4", "#5", "#6", "#7", "#8", "#9", "#10", "#14", "#15", "#17"}
SCREEN_SCRIPTS = {"#11", "#12", "#13", "#16", "#17"}
COMBO_SCRIPTS = {"#4", "#5", "#6", "#7", "#8"}


def clip_profile(script: str) -> dict[str, bool]:
    return {
        "glossary_sweep": script in GLOSSARY_SCRIPTS,
        "screen_sweep": script in SCREEN_SCRIPTS,
        "combo_default": script in COMBO_SCRIPTS,
    }


def is_regurgitation(raw: str, decoder_context: str | None, terms: list[str]) -> bool:
    stripped = raw.strip()
    if not stripped:
        return False
    if FILENAME_RE.fullmatch(stripped) or FILENAME_RE.fullmatch(stripped.rstrip(".")):
        return True
    if len(stripped) < 80 and steering_overlap_fraction(stripped, terms) >= 0.85:
        return True
    if decoder_context and stripped.replace(" ", "") in decoder_context.replace(" ", ""):
        if len(stripped.split()) <= 6:
            return True
    return False


def score_row(
    raw: str,
    baseline: str,
    reference: str,
    clip: ReadAloudClip,
    terms: list[str],
    decoder_context: str | None,
    ctx_chars: int,
) -> dict:
    base = score_transcript(
        raw,
        reference,
        expect_swift=clip.expect_coordinator_swift,
        expect_token=clip.expect_glossary_token,
    )
    return {
        **base,
        "baseline_distance": normalized_levenshtein(raw, baseline),
        "reference_token_recall": reference_token_recall(raw, reference),
        "steering_overlap": steering_overlap_fraction(raw, terms),
        "has_ut_finish_swift": bool(UT_FINISH_RE.search(raw)),
        "has_voicey_text": bool(VOICEY_TEXT_RE.search(raw)),
        "regurgitation": is_regurgitation(raw, decoder_context, terms),
        "context_chars": ctx_chars,
        "term_count": len(terms),
    }


def run_sweep_for_profile(
    supervisor: JsonlWorker,
    text_worker: JsonlWorker,
    *,
    shm: str,
    count: int,
    model: str,
    clip: ReadAloudClip,
    baseline: str,
    snapshot: dict | None,
    profile: str,
    configs: list[CapConfig],
) -> list[dict]:
    rows: list[dict] = []
    for config in configs:
        if profile == "glossary":
            out = build_steering(
                text_worker,
                config,
                manual_glossary_enabled=True,
                manual_glossary=DEFAULT_GLOSSARY,
                screen_context_enabled=False,
                snapshot=None,
            )
        elif profile == "screen":
            out = build_steering(
                text_worker,
                config,
                manual_glossary_enabled=False,
                manual_glossary="",
                screen_context_enabled=True,
                snapshot=snapshot,
            )
        elif profile == "combo":
            out = build_steering(
                text_worker,
                config,
                manual_glossary_enabled=True,
                manual_glossary=DEFAULT_GLOSSARY,
                screen_context_enabled=True,
                snapshot=snapshot,
            )
        else:
            raise ValueError(profile)

        terms = out.get("terms") or []
        ctx = out.get("decoder_context")
        raw = transcribe(
            supervisor,
            model=model,
            shm_name=shm,
            sample_count=count,
            decoder_context=ctx,
            language=None,
        )
        rows.append(
            {
                "profile": profile,
                "config": asdict(config),
                "raw_text": raw,
                **score_row(raw, baseline, clip.reference, clip, terms, ctx, len(ctx or "")),
            }
        )
    return rows


def pick_best(rows: list[dict], *, filename_clip: bool, false_positive: bool) -> dict | None:
    if not rows:
        return None
    if false_positive:
        # Prefer low steering overlap and close to baseline (no glossary soup)
        best = min(
            rows,
            key=lambda r: (r["steering_overlap"], r["baseline_distance"], r["reference_levenshtein"]),
        )
    elif filename_clip:
        best = min(
            rows,
            key=lambda r: (
                0 if r["has_swift_filename"] else 1,
                r["reference_levenshtein"],
                r["regurgitation"],
                r["baseline_distance"],
            ),
        )
    else:
        best = min(
            rows,
            key=lambda r: (r["reference_levenshtein"], r["baseline_distance"], r["steering_overlap"]),
        )
    return best


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive-root", type=Path, default=default_archive_root())
    parser.add_argument("--model", default="qwen3-asr-1.7b-bf16")
    parser.add_argument(
        "--out",
        type=Path,
        default=REPO_ROOT / "benchmark-results" / "readaloud-deep-analysis.json",
    )
    args = parser.parse_args()

    configs = cap_grid(SCREEN_SWEEP, TERM_SWEEP, CHAR_SWEEP)
    default_cap = CapConfig(16, 48, 512)

    voicey = resolve_voicey()
    env = worker_env(voicey)
    supervisor = JsonlWorker(str(resolve_worker("voicey-supervisor")), env=env)
    capture = JsonlWorker(str(resolve_worker("voicey-capture")), env=env)
    text_worker = JsonlWorker(str(resolve_worker("voicey-text")))

    report: dict = {
        "model": args.model,
        "glossary": DEFAULT_GLOSSARY,
        "sweep_configs": [asdict(c) for c in configs],
        "clips": [],
        "aggregate": {},
    }

    cap_wins: dict[str, list[dict]] = defaultdict(list)

    try:
        pre = supervisor.request({"type": "prewarm_infer", "model_id": args.model})
        if pre.get("type") not in {"infer_ready", "ready"}:
            raise RuntimeError(pre)

        total = len(READALOUD_CLIPS)
        for index, clip in enumerate(READALOUD_CLIPS, start=1):
            print(f"[{index}/{total}] {clip.script} {clip.id_prefix}", file=sys.stderr)
            rec = load_record(args.archive_root, clip.id_prefix)
            uid = rec["id"].replace("-", "")
            snap_path = args.archive_root / "snapshots" / f"{uid}.json"
            snapshot = json.loads(snap_path.read_text()) if snap_path.is_file() else None
            wav = args.archive_root / rec["audio_path"]
            shm, count = load_wav_pcm(capture, wav)

            baseline = transcribe(
                supervisor,
                model=args.model,
                shm_name=shm,
                sample_count=count,
                decoder_context=None,
                language=None,
            )

            profiles = clip_profile(clip.script)
            entry: dict = {
                "id": rec["id"],
                "script": clip.script,
                "reference": clip.reference,
                "expect_swift_filename": clip.expect_coordinator_swift,
                "live": {
                    "raw_text": rec.get("raw_text"),
                    "glossary_enabled": rec.get("glossary_enabled"),
                    "screen_context_enabled": rec.get("screen_context_enabled"),
                    "steering_term_count": len(rec.get("steering_terms") or []),
                },
                "baseline": {
                    "raw_text": baseline,
                    **score_row(baseline, baseline, clip.reference, clip, [], None, 0),
                },
                "defaults": {},
                "sweeps": {},
                "recommendations": {},
            }

            for label, cap, prof in [
                ("glossary_default", default_cap, "glossary"),
                ("combo_default", default_cap, "combo"),
                ("screen_default", default_cap, "screen"),
            ]:
                if prof == "combo" and clip.script not in COMBO_SCRIPTS:
                    continue
                if prof == "screen" and not snapshot:
                    continue
                row = run_sweep_for_profile(
                    supervisor,
                    text_worker,
                    shm=shm,
                    count=count,
                    model=args.model,
                    clip=clip,
                    baseline=baseline,
                    snapshot=snapshot,
                    profile=prof,
                    configs=[cap],
                )[0]
                entry["defaults"][label] = row

            if profiles["glossary_sweep"]:
                entry["sweeps"]["glossary"] = run_sweep_for_profile(
                    supervisor,
                    text_worker,
                    shm=shm,
                    count=count,
                    model=args.model,
                    clip=clip,
                    baseline=baseline,
                    snapshot=snapshot,
                    profile="glossary",
                    configs=configs,
                )
            if profiles["screen_sweep"] and snapshot:
                entry["sweeps"]["screen"] = run_sweep_for_profile(
                    supervisor,
                    text_worker,
                    shm=shm,
                    count=count,
                    model=args.model,
                    clip=clip,
                    baseline=baseline,
                    snapshot=snapshot,
                    profile="screen",
                    configs=configs,
                )
            if profiles["combo_default"] and snapshot:
                entry["sweeps"]["combo"] = run_sweep_for_profile(
                    supervisor,
                    text_worker,
                    shm=shm,
                    count=count,
                    model=args.model,
                    clip=clip,
                    baseline=baseline,
                    snapshot=snapshot,
                    profile="combo",
                    configs=configs,
                )

            fp = clip.script in {"#14", "#15"}
            for sweep_name, sweep_rows in entry["sweeps"].items():
                best = pick_best(
                    sweep_rows,
                    filename_clip=clip.expect_coordinator_swift,
                    false_positive=fp,
                )
                if best:
                    entry["recommendations"][sweep_name] = {
                        "config": best["config"],
                        "raw_text": best["raw_text"],
                        "has_swift_filename": best["has_swift_filename"],
                        "regurgitation": best["regurgitation"],
                        "reference_levenshtein": best["reference_levenshtein"],
                        "baseline_distance": best["baseline_distance"],
                    }
                    cap_wins[sweep_name].append(best["config"])

            report["clips"].append(entry)

        # Mode-level aggregate: most common winning config keys per profile
        for mode, configs_won in cap_wins.items():
            if not configs_won:
                continue
            key_counts: dict[str, int] = defaultdict(int)
            for c in configs_won:
                key_counts[json.dumps(c, sort_keys=True)] += 1
            winner = max(key_counts.items(), key=lambda x: x[1])
            report["aggregate"][mode] = {
                "winning_config": json.loads(winner[0]),
                "clip_wins": winner[1],
            }

        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps(report, indent=2), encoding="utf-8")
        print_summary(report)
        print(f"\nWrote {args.out}", file=sys.stderr)
    finally:
        text_worker.close()
        capture.close()
        supervisor.close()

    return 0


def print_summary(report: dict) -> None:
    print("\n=== Deep read-aloud steering summary ===\n", file=sys.stderr)
    for clip in report["clips"]:
        script = clip["script"]
        live = clip["live"]["raw_text"] or ""
        base = clip["baseline"]["raw_text"] or ""
        print(f"{script} ({clip['id'][:8]})", file=sys.stderr)
        print(f"  live:     {live[:90]}{'…' if len(live)>90 else ''}", file=sys.stderr)
        print(f"  baseline: {base[:90]}{'…' if len(base)>90 else ''}", file=sys.stderr)
        gd = clip.get("defaults", {}).get("glossary_default")
        if gd:
            swift = " .swift" if gd.get("has_swift_filename") else ""
            reg = " REGURGE" if gd.get("regurgitation") else ""
            print(
                f"  glossary@512: {gd['raw_text'][:85]}{'…' if len(gd['raw_text'])>85 else ''}{swift}{reg}",
                file=sys.stderr,
            )
        for mode, rec in clip.get("recommendations", {}).items():
            c = rec["config"]
            print(
                f"  best-{mode}: s{c['max_screen_terms']}/t{c['max_terms']}/c{c['max_context_chars']} "
                f"swift={rec['has_swift_filename']} reg={rec['regurgitation']} "
                f"ref_d={rec['reference_levenshtein']:.3f}",
                file=sys.stderr,
            )
        print(file=sys.stderr)

    print("Aggregate cap winners:", file=sys.stderr)
    for mode, agg in report.get("aggregate", {}).items():
        print(f"  {mode}: {agg['winning_config']} ({agg['clip_wins']} clips)", file=sys.stderr)


if __name__ == "__main__":
    raise SystemExit(main())
