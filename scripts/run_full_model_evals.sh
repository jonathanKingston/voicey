#!/usr/bin/env bash
# Run read-aloud + quality eval permutations (macOS, local models). Logs under benchmark-results/.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

ART="${VOICEY_READALOUD_ARCHIVE:-$HOME/Library/Application Support/Voicey/Artifacts/readaloud-corpus-v3}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$REPO_ROOT/benchmark-results/full-eval-$TS"
mkdir -p "$OUT"
LOG="$OUT/run.log"
exec > >(tee -a "$LOG") 2>&1

echo "=== Voicey full eval run $TS ==="
echo "read-aloud archive: $ART"
test -f "$ART/index.jsonl" || { echo "missing artifact bundle: $ART"; exit 1; }

run() {
  echo ""
  echo ">>> $*"
  "$@"
}

MODELS=(qwen3-asr-1.7b-bf16 qwen3-asr-0.6b-6bit)

for MODEL in "${MODELS[@]}"; do
  SLUG="${MODEL//\//-}"
  run python3 scripts/eval_readaloud_artificial_steering.py \
    --archive-root "$ART" \
    --model "$MODEL" \
    --out "$OUT/readaloud-steering-${SLUG}.json"

  run python3 scripts/eval_readaloud_runtime_matrix.py \
    --archive-root "$ART" \
    --model "$MODEL" \
    --output-dir "$OUT/readaloud-runtime-${SLUG}"

  run python3 scripts/deep_readaloud_steering_analysis.py \
    --archive-root "$ART" \
    --model "$MODEL" \
    --out "$OUT/readaloud-deep-${SLUG}.json"
done

run python3 scripts/eval_readaloud_delivery_matrix.py \
  --archive-root "$ART" \
  --out "$OUT/readaloud-delivery-matrix.json"

run python3 scripts/broad_steering_analysis.py \
  --archive-root "$ART" \
  --model qwen3-asr-1.7b-bf16 \
  --readaloud-out "$OUT/broad-readaloud-1.7b.json" \
  --out "$OUT/broad-steering-analysis.json" \
  --skip-common-voice

echo ">>> attempting Common Voice prepare (25 clips) + steering modes..."
if command -v ffmpeg >/dev/null 2>&1 && make benchmark-prepare-common-voice BENCHMARK_COMMON_VOICE_LIMIT=25 2>&1; then
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
    run python3 scripts/broad_steering_analysis.py \
      --archive-root "$ART" \
      --model qwen3-asr-1.7b-bf16 \
      --readaloud-out "$OUT/broad-readaloud-1.7b.json" \
      --common-voice-out "$OUT/common-voice-steering-qwen3-asr-1.7b-bf16.json" \
      --out "$OUT/broad-steering-with-cv.json" || true
  fi
else
  echo ">>> skip Common Voice (prepare failed — install ffmpeg: brew install ffmpeg)"
fi

echo ">>> attempting LibriSpeech prepare + transcription quality matrix (all improvement variants)..."
require_ffmpeg() {
  if ! command -v ffmpeg >/dev/null 2>&1; then
    echo ">>> skip LibriSpeech quality matrix (install ffmpeg: brew install ffmpeg)"
    return 1
  fi
  return 0
}

SMOKE_TSV="$REPO_ROOT/benchmark-data/common-voice/prepared/librispeech_clean/test-limit200-seed20260506/test.tsv"
LS_LIMIT=200
if [[ ! -f "$SMOKE_TSV" ]] && require_ffmpeg; then
  make benchmark-download-librispeech-dev-clean || true
  make benchmark-prepare-librispeech-sample BENCHMARK_LIBRISPEECH_LIMIT=200 \
    || make benchmark-prepare-librispeech-sample BENCHMARK_LIBRISPEECH_LIMIT=25 || true
fi
if [[ ! -f "$SMOKE_TSV" ]]; then
  SMOKE_TSV="$REPO_ROOT/benchmark-data/common-voice/prepared/librispeech_clean/test-limit25-seed20260506/test.tsv"
  LS_LIMIT=25
fi
if [[ -f "$SMOKE_TSV" ]] && require_ffmpeg; then
  LS_PREPARED="${SMOKE_TSV%/*}"
  GLOSS="$REPO_ROOT/Benchmarks/eval_proper_noun_glossary.txt"
  if [[ -f "$GLOSS" && ! -f "$LS_PREPARED/eval_proper_noun_glossary.txt" ]]; then
    cp "$GLOSS" "$LS_PREPARED/eval_proper_noun_glossary.txt"
  fi
  run python3 scripts/eval_transcription_quality_matrix.py \
    --tsv "$SMOKE_TSV" \
    --clips-dir "$LS_PREPARED/clips" \
    --limit "$LS_LIMIT" \
    --output-dir "$OUT/quality-matrix-librispeech-${LS_LIMIT}-all-variants"
elif [[ ! -f "$SMOKE_TSV" ]]; then
  echo ">>> skip LibriSpeech quality matrix (no prepared corpus)"
fi

python3 - <<PY
import json
from pathlib import Path
out = Path("$OUT")
artifacts = sorted(
  str(p.relative_to(out))
  for p in out.rglob("*")
  if p.is_file() and p.name != ".DS_Store"
)
manifest = {"timestamp": "$TS", "archive_root": "$ART", "artifacts": artifacts}
(out / "MANIFEST.json").write_text(json.dumps(manifest, indent=2) + "\n")
print("Wrote", out / "MANIFEST.json", f"({len(artifacts)} files)")
PY

echo ""
echo "=== Done. Results: $OUT ==="
