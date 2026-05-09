#!/usr/bin/env bash
# Clone and build ungive/mediaremote-adapter, copy MediaRemoteAdapter.framework
# into Voicey's MediaRemoteAdapterBundled folder (BSD 3-Clause — see upstream).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST_DIR="$ROOT/Sources/Voicey/MediaRemoteAdapterBundled"
DEST_FW="$DEST_DIR/MediaRemoteAdapter.framework"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/voicey-mra-XXXXXX")"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

REPO_URL="${MEDIAREMOTE_ADAPTER_REPO_URL:-https://github.com/ungive/mediaremote-adapter.git}"
REF="${MEDIAREMOTE_ADAPTER_REF:-master}"

echo "Cloning $REPO_URL ($REF)…"
git clone --depth 1 --branch "$REF" "$REPO_URL" "$WORKDIR/repo"

echo "Configuring CMake…"
cmake -S "$WORKDIR/repo" -B "$WORKDIR/build" -DCMAKE_BUILD_TYPE=Release

echo "Building MediaRemoteAdapter.framework…"
NCPU="$( (command -v sysctl >/dev/null && sysctl -n hw.ncpu) || echo 4)"
cmake --build "$WORKDIR/build" --parallel "$NCPU"

BUILT="$WORKDIR/build/MediaRemoteAdapter.framework"
if [[ ! -d "$BUILT" ]]; then
  echo "error: expected framework at $BUILT" >&2
  exit 1
fi

mkdir -p "$DEST_DIR"
rm -rf "$DEST_FW"
cp -R "$BUILT" "$DEST_FW"
echo "Installed: $DEST_FW"
