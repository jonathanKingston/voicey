#!/usr/bin/env bash
# Bundle the Apple Speech CLI so macOS TCC sees NSSpeechRecognitionUsageDescription.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/Benchmarks/AppleSpeech"
BIN="$PKG/.build/debug/voicey-apple-speech-benchmark"
APP="$PKG/voicey-apple-speech-benchmark.app"

if [[ ! -f "$BIN" ]]; then
  echo "error: build the binary first (make build-apple-speech-benchmark)" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/voicey-apple-speech-benchmark"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>voicey-apple-speech-benchmark</string>
  <key>CFBundleIdentifier</key>
  <string>work.voicey.apple-speech-benchmark</string>
  <key>CFBundleName</key>
  <string>voicey-apple-speech-benchmark</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Voicey uses Apple Speech for offline benchmark comparisons.</string>
</dict>
</plist>
EOF

echo "Bundled $APP"
