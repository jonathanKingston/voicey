#!/usr/bin/env bash
# macOS memory snapshot: warm infer-worker after load + multiprocess benchmark parent peak.
# Note: MLX weights often live in unified GPU memory; ps RSS under-reports vs time -l peak.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VOICEY="${VOICEY_BINARY:-$ROOT/.build/debug/Voicey}"
MODEL="${1:-qwen3-asr-0.6b-6bit}"
AUDIO="${2:-$ROOT/Benchmarks/Golden/tone_1p0s_220hz.wav}"
OUT_DIR="${VOICEY_MEMORY_OUT_DIR:-$ROOT/benchmark-results}"

if [[ ! -x "$VOICEY" ]]; then
  echo "error: build Voicey first (make build)" >&2
  exit 1
fi

for worker in voicey-supervisor voicey-fetch voicey-text; do
  if [[ ! -x "$ROOT/.build/debug/$worker" && ! -x "$ROOT/target/debug/$worker" ]]; then
    echo "error: missing $worker (run make build-rust)" >&2
    exit 1
  fi
done

mkdir -p "$OUT_DIR"

rss_kb() {
  ps -o rss= -p "$1" 2>/dev/null | tr -d ' '
}

parse_time_peak_bytes() {
  local file="$1"
  awk '/maximum resident set size/ { print $1; exit }' "$file"
}

echo "=== Multiprocess infer-worker after load_model (idle, kept alive) ===" >&2
FIFO="$(mktemp -u /tmp/voicey-infer-XXXX)"
WORKER_LOG="$(mktemp)"
mkfifo "$FIFO"
trap 'rm -f "$FIFO" "$WORKER_LOG"' EXIT

"$VOICEY" infer-worker <"$FIFO" >"$WORKER_LOG" 2>/dev/null &
WORKER_PID=$!

exec 3>"$FIFO"
printf '%s\n' "{\"type\":\"load_model\",\"id\":\"mem1\",\"model_id\":\"$MODEL\"}" >&3

DEADLINE=$((SECONDS + 180))
while (( SECONDS < DEADLINE )); do
  if grep -q infer_ready "$WORKER_LOG"; then
    break
  fi
  if ! kill -0 "$WORKER_PID" 2>/dev/null; then
    echo "error: infer-worker exited during load" >&2
    cat "$WORKER_LOG" >&2
    exit 1
  fi
  sleep 1
done

if ! grep -q infer_ready "$WORKER_LOG"; then
  echo "error: timed out waiting for infer_ready" >&2
  cat "$WORKER_LOG" >&2
  exit 1
fi

sleep 2
MAX_RSS_KB=0
for _ in $(seq 1 15); do
  RSS="$(rss_kb "$WORKER_PID" || echo 0)"
  if [[ "$RSS" -gt "$MAX_RSS_KB" ]]; then
    MAX_RSS_KB="$RSS"
  fi
  sleep 1
done

FOOTPRINT_LINE=""
if command -v footprint >/dev/null 2>&1; then
  FOOTPRINT_LINE="$(footprint "$WORKER_PID" 2>/dev/null | head -3 | tr '\n' ' ' || true)"
fi

MP_TIME_LOG="$(mktemp)"
/usr/bin/time -l "$VOICEY" benchmark-transcribe \
  --model "$MODEL" \
  --audio "$AUDIO" \
  --runtime multiprocess \
  --post-process \
  --warmup 1 \
  --json >/dev/null 2>"$MP_TIME_LOG" || true
MP_PEAK_BYTES="$(parse_time_peak_bytes "$MP_TIME_LOG" || echo 0)"
rm -f "$MP_TIME_LOG"

kill "$WORKER_PID" 2>/dev/null || true
wait "$WORKER_PID" 2>/dev/null || true

python3 - <<PY
import json

mp_peak = int("${MP_PEAK_BYTES:-0}")
worker_rss = int("${MAX_RSS_KB:-0}")

def mb(b):
    return round(b / (1024 * 1024), 1) if b else None

payload = {
    "model": "$MODEL",
    "audio": "$AUDIO",
    "multiprocessBenchmarkParentPeakRSS_MB": mb(mp_peak),
    "multiprocessBenchmarkParentPeakNote": (
        "time -l on benchmark-transcribe measures the CLI parent; MLX weights live in the infer-worker child."
    ),
    "inferWorkerIdleRSS_MB_ps": round(worker_rss / 1024, 1),
    "mlxMemoryNote": (
        "Qwen/MLX allocates much of the model in unified GPU memory. "
        "ps RSS on infer-worker alone is often far below real working set; "
        "use SpeechModel.memoryUsage in ModelManager for capacity planning."
    ),
    "planningEstimateFromModelManager": {
        "qwen3-asr-0.6b-6bit": "~1300 MB",
        "qwen3-asr-1.7b-bf16": "~3500 MB",
    },
    "inferWorkerIdleFootprintSample": "${FOOTPRINT_LINE}".strip() or None,
}
print(json.dumps(payload, indent=2))
PY
