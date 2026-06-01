#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VOICEY_BIN="${VOICEY_BINARY:-$ROOT/.build/debug/Voicey}"
MODEL="${1:-qwen3-asr-0.6b-6bit}"
AUDIO="${2:-$ROOT/Benchmarks/Golden/tone_0p5s_440hz.wav}"
RTF_MAX="${VOICEY_BENCHMARK_RTF_MAX:-1.0}"
WARMUP="${VOICEY_BENCHMARK_WARMUP:-1}"

if [[ ! -x "$VOICEY_BIN" ]]; then
  echo "error: Voicey binary not found at $VOICEY_BIN (run make build)" >&2
  exit 1
fi

for worker in voicey-supervisor voicey-fetch voicey-capture voicey-text; do
  if [[ ! -x "$ROOT/.build/debug/$worker" && ! -x "$ROOT/target/debug/$worker" ]]; then
    echo "error: missing $worker (run make build-rust)" >&2
    exit 1
  fi
done

if [[ ! -f "$AUDIO" ]]; then
  python3 "$ROOT/scripts/generate_golden_fixtures.py"
fi

MP_JSON="$(mktemp)"
trap 'rm -f "$MP_JSON"' EXIT

"$VOICEY_BIN" benchmark-transcribe \
  --model "$MODEL" \
  --audio "$AUDIO" \
  --json \
  --post-process \
  --runtime multiprocess \
  --warmup "$WARMUP" >"$MP_JSON"

python3 - "$MP_JSON" "$RTF_MAX" <<'PY'
import json, sys

mp_path, rtf_max = sys.argv[1:3]
max_rtf = float(rtf_max)

with open(mp_path, encoding="utf-8") as handle:
    payload = json.load(handle)

def fail(msg):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)

if payload.get("runtime") != "multiprocess":
    fail(f"expected runtime multiprocess, got {payload.get('runtime')!r}")

for key in ("model", "audio", "rawText", "text", "processingSeconds", "audioSeconds"):
    if key not in payload:
        fail(f"JSON missing required field: {key}")

audio_seconds = float(payload.get("audioSeconds") or 0)
if audio_seconds <= 0:
    fail("invalid audioSeconds")

mp_rtf = float(payload.get("realTimeFactor") or 0)
if mp_rtf <= 0:
    fail("invalid multiprocess RTF")
if mp_rtf > max_rtf:
    fail(f"multiprocess RTF {mp_rtf:.3f} exceeds {max_rtf}")

raw_text = payload.get("rawText") or ""
text = payload.get("text") or ""
# Tone fixtures often yield empty ASR output; smoke test is exit 0 + voicey-text round-trip keys.
if raw_text.strip() and not text.strip():
    fail("post-process returned empty text for non-empty rawText")

print(json.dumps({
    "model": payload.get("model"),
    "audio": payload.get("audio"),
    "multiprocessRTF": mp_rtf,
    "rawTextLength": len(raw_text.strip()),
    "textLength": len(text.strip()),
}, indent=2))
PY
