#!/bin/bash
set -e

# Bump CFBundleShortVersionString and CFBundleVersion in all plist files.
# Usage: ./scripts/bump-version.sh 1.2.0

VERSION="$1"

if [ -z "$VERSION" ]; then
  echo "Usage: $0 <version>"
  echo "Example: $0 1.2.0"
  exit 1
fi

# Validate version format (major.minor.patch)
if ! echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "Error: Version must be in major.minor.patch format (e.g. 1.2.0)"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

PLISTS=("$ROOT_DIR/Info.plist" "$ROOT_DIR/Info.direct.plist")

for PLIST in "${PLISTS[@]}"; do
  if [ ! -f "$PLIST" ]; then
    echo "Warning: $PLIST not found, skipping"
    continue
  fi
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$PLIST"
  echo "Updated $(basename "$PLIST") → $VERSION"
done

# Keep project.yml MARKETING_VERSION in sync (used by XcodeGen)
PROJECT_YML="$ROOT_DIR/project.yml"
if [ -f "$PROJECT_YML" ]; then
  sed -i '' "s/MARKETING_VERSION: \"[0-9]*\.[0-9]*\.[0-9]*\"/MARKETING_VERSION: \"$VERSION\"/" "$PROJECT_YML"
  echo "Updated project.yml → $VERSION"
fi
