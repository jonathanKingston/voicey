#!/usr/bin/env bash
# Resume Common Voice + LibriSpeech quality-matrix steps for an existing full-eval output dir.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

ART="${VOICEY_READALOUD_ARCHIVE:-$HOME/Library/Application Support/Voicey/Artifacts/readaloud-corpus-v3}"
OUT="${VOICEY_FULL_EVAL_OUT:-}"
if [[ -z "$OUT" ]]; then
  OUT="$(ls -td "$REPO_ROOT"/benchmark-results/full-eval-* 2>/dev/null | head -1 || true)"
fi
if [[ -z "$OUT" || ! -d "$OUT" ]]; then
  echo "Set VOICEY_FULL_EVAL_OUT to an existing benchmark-results/full-eval-* directory" >&2
  exit 1
fi

LOG="$OUT/run.log"
exec >>"$LOG" 2>&1

echo ""
echo "=== Voicey full eval continuation $(date -u +%Y%m%dT%H%M%SZ) ==="
echo "output: $OUT"
echo "read-aloud archive: $ART"

require_ffmpeg() {
  if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "error: ffmpeg required (brew install ffmpeg) for MP3/FLAC benchmark clips" >&2
    exit 1
  fi
}

run() {
  echo ""
  echo ">>> $*"
  "$@"
}

write_manifest() {
  python3 - <<PY
import json
from pathlib import Path
out = Path("$OUT")
artifacts = sorted(
  str(p.relative_to(out))
  for p in out.rglob("*")
  if p.is_file() and p.name != ".DS_Store"
)
manifest = {
  "timestamp": out.name.removeprefix("full-eval-"),
  "archive_root": "$ART",
  "artifacts": artifacts,
}
(out / "MANIFEST.json").write_text(json.dumps(manifest, indent=2) + "\n")
print("Wrote", out / "MANIFEST.json", f"({len(artifacts)} files)")
PY
}

require_ffmpeg

MODELS=(qwen3-asr-1.7b-bf16 qwen3-asr-0.6b-6bit)

echo ">>> Common Voice prepare (25 clips) + steering modes..."
if make benchmark-prepare-common-voice BENCHMARK_COMMON_VOICE_LIMIT=25; then
  CV_DIR="$REPO_ROOT/benchmark-data/common-voice/prepared/cmkfm9fbl00nto0070sdcrak2/test-limit25-seed20260506"
  if [[ -f "$CV_DIR/test.tsv" ]]; then
    for MODEL in "${MODELS[@]}"; do
      SLUG="${MODEL//\//-}"
      run python3 scripts/eval_common_voice_steering.py \
        --model "$MODEL" \
        --tsv "$CV_DIR/test.tsv" \
        --clips-dir "$CV_DIR/clips" \
        --limit 25 \
        --out "$OUT/common-voice-steering-${SLUG}.json" || true
    done
    if [[ -f "$OUT/broad-readaloud-1.7b.json" ]]; then
      run python3 scripts/broad_steering_analysis.py \
        --archive-root "$ART" \
        --model qwen3-asr-1.7b-bf16 \
        --readaloud-out "$OUT/broad-readaloud-1.7b.json" \
        --common-voice-out "$OUT/common-voice-steering-qwen3-asr-1.7b-bf16.json" \
        --out "$OUT/broad-steering-with-cv.json" || true
    fi
  else
    echo ">>> Common Voice TSV missing after prepare: $CV_DIR"
  fi
else
  echo ">>> Common Voice prepare failed"
fi

echo ">>> LibriSpeech prepare + transcription quality matrix..."
LS_TSV="$REPO_ROOT/benchmark-data/common-voice/prepared/librispeech_clean/test-limit200-seed20260506/test.tsv"
LS_LIMIT=200
if [[ ! -f "$LS_TSV" ]]; then
  make benchmark-download-librispeech-dev-clean
  if make benchmark-prepare-librispeech-sample BENCHMARK_LIBRISPEECH_LIMIT=200; then
    LS_TSV="$REPO_ROOT/benchmark-data/common-voice/prepared/librispeech_clean/test-limit200-seed20260506/test.tsv"
  else
    echo ">>> falling back to 25-clip LibriSpeech sample"
    make benchmark-prepare-librispeech-sample BENCHMARK_LIBRISPEECH_LIMIT=25 || true
    LS_TSV="$REPO_ROOT/benchmark-data/common-voice/prepared/librispeech_clean/test-limit25-seed20260506/test.tsv"
    LS_LIMIT=25
  fi
fi

if [[ -f "$LS_TSV" ]]; then
  LS_PREPARED_DIR="${LS_TSV%/*}"
  LS_CLIPS_DIR="$LS_PREPARED_DIR/clips"
  GLOSS="$REPO_ROOT/Benchmarks/eval_proper_noun_glossary.txt"
  if [[ -f "$GLOSS" && ! -f "$LS_PREPARED_DIR/eval_proper_noun_glossary.txt" ]]; then
    cp "$GLOSS" "$LS_PREPARED_DIR/eval_proper_noun_glossary.txt"
  fi
  OUT_SUB="quality-matrix-librispeech-${LS_LIMIT}-all-variants"
  if ! compgen -G "$OUT/$OUT_SUB/*/summary.json" >/dev/null; then
    run python3 scripts/eval_transcription_quality_matrix.py \
      --tsv "$LS_TSV" \
      --clips-dir "$LS_CLIPS_DIR" \
      --limit "$LS_LIMIT" \
      --output-dir "$OUT/$OUT_SUB"
  else
    echo ">>> LibriSpeech quality matrix already present under $OUT/$OUT_SUB"
  fi
  if [[ -f "$GLOSS" ]]; then
    run python3 scripts/eval_transcription_quality_matrix.py \
      --tsv "$LS_TSV" \
      --clips-dir "$LS_CLIPS_DIR" \
      --glossary-file "$GLOSS" \
      --limit "$LS_LIMIT" \
      --output-dir "$OUT/$OUT_SUB" \
      --variants repair-glossary-1.7b steer-glossary-1.7b-raw steer-glossary-1.7b-proc || true
  fi
else
  echo ">>> skip LibriSpeech quality matrix (prepare failed — need dev-clean.tar.gz)"
fi

write_manifest

echo ""
echo "=== Continuation done. Results: $OUT ==="
