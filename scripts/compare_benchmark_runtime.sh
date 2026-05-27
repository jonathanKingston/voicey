#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VOICEY_BIN="${VOICEY_BINARY:-$ROOT/.build/debug/Voicey}"
MODEL="${1:-qwen3-asr-0.6b-6bit}"
AUDIO="${2:-$ROOT/Benchmarks/Golden/tone_0p5s_440hz.wav}"
RTF_MAX="${VOICEY_BENCHMARK_RTF_MAX:-1.05}"
WARMUP="${VOICEY_BENCHMARK_WARMUP:-1}"

if [[ ! -x "$VOICEY_BIN" ]]; then
  echo "error: Voicey binary not found at $VOICEY_BIN (run make build)" >&2
  exit 1
fi

if [[ ! -f "$AUDIO" ]]; then
  python3 "$ROOT/scripts/generate_golden_fixtures.py"
fi

IN_JSON="$(mktemp)"
MP_JSON="$(mktemp)"
trap 'rm -f "$IN_JSON" "$MP_JSON"' EXIT

"$VOICEY_BIN" benchmark-transcribe \
  --model "$MODEL" \
  --audio "$AUDIO" \
  --json \
  --post-process \
  --runtime in-process \
  --warmup "$WARMUP" >"$IN_JSON"

"$VOICEY_BIN" benchmark-transcribe \
  --model "$MODEL" \
  --audio "$AUDIO" \
  --json \
  --post-process \
  --runtime multiprocess \
  --warmup "$WARMUP" >"$MP_JSON"

python3 - "$IN_JSON" "$MP_JSON" "$RTF_MAX" <<'PY'
import json, sys

in_path, mp_path, rtf_max = sys.argv[1:4]
max_ratio = float(rtf_max)

with open(in_path, encoding="utf-8") as handle:
    in_payload = json.load(handle)
with open(mp_path, encoding="utf-8") as handle:
    mp_payload = json.load(handle)

def fail(msg):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)

if in_payload.get("rawText") != mp_payload.get("rawText"):
    fail("rawText mismatch between in-process and multiprocess")

if in_payload.get("text") != mp_payload.get("text"):
    fail("post-process text mismatch between in-process and multiprocess")

in_rtf = float(in_payload.get("realTimeFactor") or 0)
mp_rtf = float(mp_payload.get("realTimeFactor") or 0)
if in_rtf <= 0:
    fail("invalid in-process RTF")

ratio = mp_rtf / in_rtf
if ratio > max_ratio:
    fail(f"multiprocess RTF ratio {ratio:.3f} exceeds {max_ratio}")

print(json.dumps({
    "model": in_payload.get("model"),
    "audio": in_payload.get("audio"),
    "inProcessRTF": in_rtf,
    "multiprocessRTF": mp_rtf,
    "rtfRatio": ratio,
    "rawTextMatch": True,
    "textMatch": True,
}, indent=2))
PY
