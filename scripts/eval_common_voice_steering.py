#!/usr/bin/env python3
"""Common Voice: baseline Qwen transcribe + replay-injected steering modes.

Downloads a small deterministic CV sample when missing (via prepare_common_voice),
prints reference vocabulary, runs audio-only baseline, flags failures (WER > 0),
then re-transcribes with oracle / miss-targeted / distractor glossaries.

Uses voicey-supervisor + 16 kHz mono WAV (ffmpeg converts MP3 clips). Output:
benchmark-results/common-voice-steering.json (gitignored). Never commit audio or results.

Requires: make build build-rust, Qwen model, MDC_API_KEY (or hf-stream) for --prepare.
"""

from __future__ import annotations

import argparse
import csv
import importlib.util
import json
import re
import shutil
import subprocess
import sys
from dataclasses import asdict, dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

from sweep_steering_caps import (
    CapConfig,
    build_steering,
    load_wav_pcm,
    resolve_voicey,
    resolve_worker,
    transcribe,
    worker_env,
)
from voicey_jsonl_worker import JsonlWorker

from readaloud_corpus_lib import blended_glossary

DEFAULT_DATASET_ID = "cmn1pv5hi00uto1072y1074y7"
DEFAULT_LIMIT = 25
DEFAULT_SEED = 20260506
DEFAULT_SPLIT = "test"
DEFAULT_PREPARED_ROOT = REPO_ROOT / "benchmark-data" / "common-voice" / "prepared"

VOICEY_LEGACY_GLOSSARY = (
    "IncrementalTranscriptionCoordinator.swift, Voicey, Qwen, voicey-text, "
    "UtteranceTranscriptionFinish.swift"
)

# Tighter caps than live defaults; matches read-aloud deep-analysis aggregate.
STEER_CAP = CapConfig(max_screen_terms=0, max_terms=32, max_context_chars=256)

STOPWORDS = frozenset(
    """
    a an the and or but if in on at to for of as is was are were be been being
    i you he she it we they my your his her its our their this that these those
    with from by not no so than too very can could should would will just
    """.split()
)

TOKEN_RE = re.compile(r"[a-z0-9']+", re.I)


@dataclass(frozen=True)
class CVClip:
    source_row: int
    relative_audio: str
    audio_path: Path
    reference: str
    client_id: str | None


def load_benchmark_module():
    path = REPO_ROOT / "scripts" / "benchmark_common_voice.py"
    spec = importlib.util.spec_from_file_location("benchmark_common_voice", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"unable to load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def load_prepare_module():
    path = REPO_ROOT / "scripts" / "prepare_common_voice.py"
    spec = importlib.util.spec_from_file_location("prepare_common_voice", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"unable to load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def default_prepared_dir(
    *,
    dataset_id: str = DEFAULT_DATASET_ID,
    split: str = DEFAULT_SPLIT,
    limit: int = DEFAULT_LIMIT,
    seed: int = DEFAULT_SEED,
    prepared_root: Path = DEFAULT_PREPARED_ROOT,
) -> Path:
    prepare = load_prepare_module()
    return prepare.prepared_directory(prepared_root, dataset_id, split, limit, seed)


def reference_tokens(text: str) -> list[str]:
    return TOKEN_RE.findall(text.lower())


def oracle_glossary_from_reference(reference: str, *, min_len: int = 5) -> str:
    """Upper-bound glossary: longer content words from the CV reference."""
    words = re.findall(r"[A-Za-z0-9']+", reference)
    picked: list[str] = []
    seen: set[str] = set()
    for word in words:
        low = word.lower()
        if low in STOPWORDS or len(word) < min_len:
            continue
        if low in seen:
            continue
        seen.add(low)
        picked.append(word)
    if picked:
        return ", ".join(picked)
    # Short utterances: use distinct reference tokens anyway.
    fallback = []
    seen.clear()
    for word in words:
        low = word.lower()
        if low in seen or low in STOPWORDS:
            continue
        seen.add(low)
        fallback.append(word)
    return ", ".join(fallback[:12]) if fallback else reference[:120]


def missed_token_glossary(reference: str, prediction: str, *, max_terms: int = 16) -> str | None:
    """Glossary from reference words absent in baseline prediction (oracle repair)."""
    ref = set(reference_tokens(reference))
    pred = set(reference_tokens(prediction))
    missed = [t for t in ref if t not in pred and t not in STOPWORDS]
    if not missed:
        return None
    missed.sort(key=len, reverse=True)
    return ", ".join(missed[:max_terms])


def load_clips_from_tsv(tsv_path: Path, clips_dir: Path) -> list[CVClip]:
    benchmark = load_benchmark_module()
    clips: list[CVClip] = []
    with tsv_path.open(encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        path_column, text_column = benchmark.resolve_columns(reader.fieldnames)
        for source_row, row in enumerate(reader, start=2):
            rel = (row.get(path_column) or "").strip()
            reference = (row.get(text_column) or "").strip()
            if not rel or not reference:
                continue
            audio_path = clips_dir / rel
            if not audio_path.is_file():
                raise SystemExit(f"missing clip {audio_path} (TSV row {source_row})")
            clips.append(
                CVClip(
                    source_row=source_row,
                    relative_audio=rel,
                    audio_path=audio_path,
                    reference=reference,
                    client_id=(row.get("client_id") or "").strip() or None,
                )
            )
    clips.sort(key=lambda c: c.source_row)
    if not clips:
        raise SystemExit(f"no clips in {tsv_path}")
    return clips


def convert_to_16k_mono_wav(source: Path, dest: Path) -> None:
    from benchmark_wav_convert import BenchmarkWavConvertError, convert_to_16k_mono_wav as convert_wav

    try:
        convert_wav(source, dest)
    except BenchmarkWavConvertError as error:
        raise SystemExit(str(error)) from error


def ensure_16k_mono_wav(source: Path, cache_dir: Path) -> Path:
    cache_dir.mkdir(parents=True, exist_ok=True)
    safe_name = source.name.replace("/", "_")
    dest = cache_dir / f"{safe_name}.16k-mono.wav"
    if dest.is_file() and dest.stat().st_mtime >= source.stat().st_mtime:
        return dest
    convert_to_16k_mono_wav(source, dest)
    return dest


def prepare_dataset(args: argparse.Namespace) -> tuple[Path, Path]:
    prepare = load_prepare_module()
    parser = prepare.build_parser()
    prepare_argv = [
        "--source",
        args.prepare_source,
        "--dataset-id",
        args.dataset_id,
        "--split",
        args.split,
        "--limit",
        str(args.limit),
        "--seed",
        str(args.seed),
        "--prepared-root",
        str(args.prepared_root),
    ]
    if args.prepare_source == "hf-stream":
        prepare_argv.extend(["--hf-dataset", args.hf_dataset, "--hf-config", args.hf_config])
    prep_args = parser.parse_args(prepare_argv)
    result = prepare.prepare_common_voice(prep_args)
    return result.tsv_path, result.clips_dir


def score_prediction(benchmark, reference: str, prediction: str) -> dict:
    metrics = benchmark.compute_text_metrics(
        reference=reference,
        prediction=prediction,
        case_sensitive=False,
        keep_punctuation=False,
    )
    return {
        "raw_text": prediction,
        "wer": metrics.wer,
        "cer": metrics.cer,
        "word_errors": metrics.word_errors,
        "reference_words": metrics.reference_words,
        "normalized_reference": metrics.normalized_reference,
        "normalized_prediction": metrics.normalized_prediction,
    }


def transcribe_with_glossary(
    *,
    supervisor: JsonlWorker,
    text_worker: JsonlWorker,
    shm: str,
    count: int,
    model: str,
    glossary: str | None,
) -> tuple[str, str | None]:
    if not glossary or not glossary.strip():
        raw = transcribe(
            supervisor,
            model=model,
            shm_name=shm,
            sample_count=count,
            decoder_context=None,
            language=None,
        )
        return raw, None
    steering = build_steering(
        text_worker,
        STEER_CAP,
        manual_glossary_enabled=True,
        manual_glossary=glossary,
        screen_context_enabled=False,
        snapshot=None,
    )
    ctx = steering.get("decoder_context")
    raw = transcribe(
        supervisor,
        model=model,
        shm_name=shm,
        sample_count=count,
        decoder_context=ctx,
        language=None,
    )
    return raw, ctx


def print_vocabulary_summary(clips: list[CVClip]) -> None:
    freq: dict[str, int] = {}
    long_words: set[str] = set()
    for clip in clips:
        for tok in reference_tokens(clip.reference):
            if tok in STOPWORDS:
                continue
            freq[tok] = freq.get(tok, 0) + 1
            if len(tok) >= 8:
                long_words.add(tok)
    top = sorted(freq.items(), key=lambda item: (-item[1], item[0]))[:20]
    print("\n=== Common Voice reference vocabulary (sample) ===", file=sys.stderr)
    print(f"Clips: {len(clips)}", file=sys.stderr)
    print(f"Distinct content tokens: {len(freq)}", file=sys.stderr)
    print(f"Tokens length ≥ 8: {len(long_words)}", file=sys.stderr)
    if top:
        print("Most frequent content tokens:", ", ".join(f"{w}×{n}" for w, n in top[:12]), file=sys.stderr)
    if long_words:
        sample_long = sorted(long_words)[:15]
        print("Sample long tokens:", ", ".join(sample_long), file=sys.stderr)
    print(file=sys.stderr)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", default="qwen3-asr-1.7b-bf16")
    parser.add_argument("--prepare", action="store_true", help="Download/extract CV sample if missing")
    parser.add_argument(
        "--prepare-source",
        default="mdc",
        choices=("mdc-stream", "mdc", "hf-stream", "archive"),
        help="prepare_common_voice source (default mdc; mdc-stream may fail on some MDC layouts)",
    )
    parser.add_argument("--dataset-id", default=DEFAULT_DATASET_ID)
    parser.add_argument("--hf-dataset", default="mozilla-foundation/common_voice_13_0")
    parser.add_argument("--hf-config", default="en")
    parser.add_argument("--split", default=DEFAULT_SPLIT)
    parser.add_argument("--limit", type=int, default=DEFAULT_LIMIT)
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED)
    parser.add_argument("--prepared-root", type=Path, default=DEFAULT_PREPARED_ROOT)
    parser.add_argument("--tsv", type=Path, default=None)
    parser.add_argument("--clips-dir", type=Path, default=None)
    parser.add_argument(
        "--failure-wer",
        type=float,
        default=0.0,
        help="Treat clips with WER above this as baseline failures (default: any error)",
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=REPO_ROOT / "benchmark-results" / "common-voice-steering.json",
    )
    parser.add_argument(
        "--wav-cache-dir",
        type=Path,
        default=None,
        help="Cache ffmpeg 16 kHz WAV conversions (default: beside prepared dir)",
    )
    return parser


def resolve_paths(args: argparse.Namespace) -> tuple[Path, Path]:
    if args.tsv and args.clips_dir:
        return args.tsv, args.clips_dir
    prepared = default_prepared_dir(
        dataset_id=args.dataset_id,
        split=args.split,
        limit=args.limit,
        seed=args.seed,
        prepared_root=args.prepared_root,
    )
    tsv = prepared / f"{args.split}.tsv"
    clips = prepared / "clips"
    if tsv.is_file() and clips.is_dir():
        return tsv, clips
    if not args.prepare:
        raise SystemExit(
            f"Prepared Common Voice sample not found at {prepared}\n"
            "Re-run with --prepare (requires MDC_API_KEY or hf-stream deps)."
        )
    tsv, clips = prepare_dataset(args)
    return tsv, clips


def main() -> int:
    args = build_parser().parse_args()
    benchmark = load_benchmark_module()

    tsv_path, clips_dir = resolve_paths(args)
    clips = load_clips_from_tsv(tsv_path, clips_dir)
    print_vocabulary_summary(clips)

    wav_cache = args.wav_cache_dir or (tsv_path.parent / "wav-16k-cache")

    voicey = resolve_voicey()
    env = worker_env(voicey)
    supervisor = JsonlWorker(str(resolve_worker("voicey-supervisor")), env=env)
    capture = JsonlWorker(str(resolve_worker("voicey-capture")), env=env)
    text_worker = JsonlWorker(str(resolve_worker("voicey-text")))

    report: dict = {
        "model": args.model,
        "tsv": str(tsv_path),
        "clips_dir": str(clips_dir),
        "steer_cap": asdict(STEER_CAP),
        "failure_wer_threshold": args.failure_wer,
        "clips": [],
        "summary": {},
    }

    try:
        prewarm = supervisor.request({"type": "prewarm_infer", "model_id": args.model})
        if prewarm.get("type") not in {"infer_ready", "ready"}:
            raise RuntimeError(f"prewarm failed: {prewarm}")

        total = len(clips)
        for index, clip in enumerate(clips, start=1):
            print(f"[{index}/{total}] row {clip.source_row} {clip.relative_audio}", file=sys.stderr)
            wav = ensure_16k_mono_wav(clip.audio_path, wav_cache)
            shm, count = load_wav_pcm(capture, wav)

            raw_baseline, _ = transcribe_with_glossary(
                supervisor=supervisor,
                text_worker=text_worker,
                shm=shm,
                count=count,
                model=args.model,
                glossary=None,
            )
            baseline_scores = score_prediction(benchmark, clip.reference, raw_baseline)
            baseline_failed = baseline_scores["wer"] > args.failure_wer

            oracle_gloss = oracle_glossary_from_reference(clip.reference)
            miss_gloss = missed_token_glossary(clip.reference, raw_baseline)

            modes: dict[str, dict] = {
                "none": {
                    **baseline_scores,
                    "glossary": None,
                    "baseline_failed": baseline_failed,
                }
            }

            blended = blended_glossary()
            for mode_name, glossary in (
                ("oracle_reference", oracle_gloss),
                ("glossary_blended", blended),
                ("glossary_voicey_legacy", VOICEY_LEGACY_GLOSSARY),
            ):
                raw, ctx = transcribe_with_glossary(
                    supervisor=supervisor,
                    text_worker=text_worker,
                    shm=shm,
                    count=count,
                    model=args.model,
                    glossary=glossary,
                )
                scores = score_prediction(benchmark, clip.reference, raw)
                modes[mode_name] = {
                    **scores,
                    "glossary": glossary,
                    "decoder_context_chars": len(ctx or ""),
                }

            if miss_gloss:
                raw, ctx = transcribe_with_glossary(
                    supervisor=supervisor,
                    text_worker=text_worker,
                    shm=shm,
                    count=count,
                    model=args.model,
                    glossary=miss_gloss,
                )
                scores = score_prediction(benchmark, clip.reference, raw)
                modes["oracle_missed_tokens"] = {
                    **scores,
                    "glossary": miss_gloss,
                    "decoder_context_chars": len(ctx or ""),
                }

            best_mode = min(modes.items(), key=lambda item: (item[1]["wer"], item[1]["cer"]))
            baseline_wer = baseline_scores["wer"]

            entry = {
                "source_row": clip.source_row,
                "audio": clip.relative_audio,
                "reference": clip.reference,
                "client_id": clip.client_id,
                "oracle_glossary": oracle_gloss,
                "baseline_failed": baseline_failed,
                "modes": modes,
                "best_mode": best_mode[0],
                "best_wer": best_mode[1]["wer"],
            }
            report["clips"].append(entry)

            if baseline_failed:
                delta_oracle = modes["oracle_reference"]["wer"] - baseline_wer
                delta_blended = modes["glossary_blended"]["wer"] - baseline_wer
                delta_legacy = modes["glossary_voicey_legacy"]["wer"] - baseline_wer
                print(
                    f"  FAIL wer={baseline_wer:.3f} ref={clip.reference[:70]!r}…"
                    if len(clip.reference) > 70
                    else f"  FAIL wer={baseline_wer:.3f} ref={clip.reference!r}",
                    file=sys.stderr,
                )
                print(f"    pred: {raw_baseline[:90]}", file=sys.stderr)
                print(
                    f"    oracle Δwer={delta_oracle:+.3f} blended Δwer={delta_blended:+.3f} "
                    f"legacy Δwer={delta_legacy:+.3f} best={best_mode[0]} ({best_mode[1]['wer']:.3f})",
                    file=sys.stderr,
                )
            else:
                print(f"  ok wer=0.000", file=sys.stderr)

        failures = [c for c in report["clips"] if c["baseline_failed"]]
        helped = 0
        hurt = 0
        unchanged = 0
        for clip in failures:
            b = clip["modes"]["none"]["wer"]
            o = clip["modes"]["oracle_reference"]["wer"]
            if o < b - 1e-9:
                helped += 1
            elif o > b + 1e-9:
                hurt += 1
            else:
                unchanged += 1

        blended_hurt = sum(
            1
            for c in report["clips"]
            if c["modes"]["glossary_blended"]["wer"] > c["modes"]["none"]["wer"] + 1e-9
        )

        report["summary"] = {
            "clip_count": len(clips),
            "glossary_blended": blended_glossary(),
            "baseline_failures": len(failures),
            "oracle_helped_failures": helped,
            "oracle_hurt_failures": hurt,
            "oracle_unchanged_failures": unchanged,
            "glossary_blended_hurt_any_clip": blended_hurt,
            "mean_wer_none": sum(c["modes"]["none"]["wer"] for c in report["clips"]) / len(clips),
            "mean_wer_oracle_reference": sum(
                c["modes"]["oracle_reference"]["wer"] for c in report["clips"]
            )
            / len(clips),
            "mean_wer_glossary_blended": sum(
                c["modes"]["glossary_blended"]["wer"] for c in report["clips"]
            )
            / len(clips),
            "mean_wer_glossary_voicey_legacy": sum(
                c["modes"]["glossary_voicey_legacy"]["wer"] for c in report["clips"]
            )
            / len(clips),
        }

        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps(report, indent=2), encoding="utf-8")

        print("\n=== Common Voice steering summary ===", file=sys.stderr)
        s = report["summary"]
        print(
            f"clips={s['clip_count']} baseline_failures={s['baseline_failures']} "
            f"mean_wer none={s['mean_wer_none']:.3f} oracle={s['mean_wer_oracle_reference']:.3f} "
            f"blended={s['mean_wer_glossary_blended']:.3f} legacy={s['mean_wer_glossary_voicey_legacy']:.3f}",
            file=sys.stderr,
        )
        print(
            f"On failures: oracle helped={helped} unchanged={unchanged} hurt={hurt}; "
            f"blended hurt {blended_hurt} clips",
            file=sys.stderr,
        )
        print(f"\nWrote {args.out}", file=sys.stderr)
    finally:
        text_worker.close()
        capture.close()
        supervisor.close()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
