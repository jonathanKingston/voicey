#!/usr/bin/env bash
# Quit Voicey and bundled Rust workers, then optionally relaunch an app bundle.
#
# Usage:
#   scripts/voicey_restart.sh                    # quit only (default)
#   scripts/voicey_restart.sh --launch PATH      # quit, then open -n PATH
#   scripts/voicey_restart.sh --launch-direct-debug  # quit, make bundle-debug-direct sign-local-debug, open repo Voicey.app
#   scripts/voicey_restart.sh --launch-installed   # quit, open /Applications/Voicey.app
#
# Environment:
#   VOICEY_RESTART_WAIT_SECONDS  Max seconds to wait for processes to exit (default: 10)
set -euo pipefail

readonly PROCESS_NAMES=(Voicey voicey-capture voicey-fetch voicey-supervisor)
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly DEFAULT_BUNDLE="${REPO_ROOT}/Voicey.app"
readonly INSTALLED_BUNDLE="/Applications/Voicey.app"

usage() {
  cat <<'EOF'
Usage: scripts/voicey_restart.sh [options]

Options:
  --quit-only              Stop Voicey and worker processes (default)
  --launch PATH            Quit, then open -n PATH (app bundle)
  --launch-direct-debug    Quit, build/sign direct debug bundle, open repo Voicey.app
  --launch-installed       Quit, then open -n /Applications/Voicey.app
  -h, --help               Show this help

Requires macOS (Darwin). Fails fast on Linux CI / Cloud Agent VMs.
EOF
}

wait_seconds="${VOICEY_RESTART_WAIT_SECONDS:-10}"
mode="quit-only"
launch_path=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quit-only)
      mode="quit-only"
      ;;
    --launch)
      mode="launch"
      shift
      if [[ $# -eq 0 ]]; then
        echo "error: --launch requires a path to Voicey.app" >&2
        exit 1
      fi
      launch_path="$1"
      ;;
    --launch-direct-debug)
      mode="launch-direct-debug"
      ;;
    --launch-installed)
      mode="launch-installed"
      launch_path="${INSTALLED_BUNDLE}"
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: voicey_restart.sh requires macOS" >&2
  exit 1
fi

any_running() {
  local name
  for name in "${PROCESS_NAMES[@]}"; do
    if pgrep -xq "$name" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

list_running() {
  local name
  for name in "${PROCESS_NAMES[@]}"; do
    pgrep -lf "$name" 2>/dev/null || true
  done
}

quit_voicey() {
  if ! any_running; then
    echo "No Voicey processes running."
    return 0
  fi

  echo "Stopping Voicey (graceful quit when possible)..."
  osascript -e 'tell application "Voicey" to quit' 2>/dev/null || true

  local deadline=$((SECONDS + wait_seconds))
  while any_running && ((SECONDS < deadline)); do
    sleep 0.25
  done

  if ! any_running; then
    echo "Voicey stopped."
    return 0
  fi

  echo "Sending SIGTERM..."
  local name
  for name in "${PROCESS_NAMES[@]}"; do
    killall -TERM "$name" 2>/dev/null || true
  done

  deadline=$((SECONDS + wait_seconds))
  while any_running && ((SECONDS < deadline)); do
    sleep 0.25
  done

  if ! any_running; then
    echo "Voicey stopped."
    return 0
  fi

  echo "Sending SIGKILL to remaining processes..."
  for name in "${PROCESS_NAMES[@]}"; do
    killall -KILL "$name" 2>/dev/null || true
  done

  sleep 0.5
  if any_running; then
    echo "error: could not stop all Voicey-related processes:" >&2
    list_running >&2
    return 1
  fi

  echo "Voicey stopped."
}

launch_bundle() {
  local bundle="$1"
  if [[ ! -d "$bundle" ]]; then
    echo "error: app bundle not found: $bundle" >&2
    exit 1
  fi
  echo "Launching ${bundle}..."
  open -n "$bundle"
}

prepare_direct_debug_bundle() {
  echo "Building and signing direct debug bundle..."
  make -C "${REPO_ROOT}" bundle-debug-direct sign-local-debug
}

quit_voicey

case "$mode" in
  quit-only)
    ;;
  launch-direct-debug)
    prepare_direct_debug_bundle
    launch_bundle "${DEFAULT_BUNDLE}"
    ;;
  launch | launch-installed)
    if [[ -z "${launch_path}" ]]; then
      echo "error: no launch path configured" >&2
      exit 1
    fi
    launch_bundle "${launch_path}"
    ;;
esac
