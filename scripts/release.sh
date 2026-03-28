#!/bin/bash
set -e

# Voicey Release Script
# Usage: ./scripts/release.sh 1.2.0

VERSION="$1"

if [ -z "$VERSION" ]; then
  echo "Usage: $0 <version>"
  echo "Example: $0 1.2.0"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

RELEASE_ENV_FILE="$ROOT_DIR/.env.release"
if [ -f "$RELEASE_ENV_FILE" ]; then
  echo "🔐 Loading release environment from $RELEASE_ENV_FILE"
  set -a
  . "$RELEASE_ENV_FILE"
  set +a
fi

PUSH_REMOTE="${PUSH_REMOTE_URL:-origin}"

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$CURRENT_BRANCH" != "main" ]; then
  echo "Error: Releases must be run from main (current: $CURRENT_BRANCH)"
  exit 1
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Error: Working tree must be clean before releasing."
  exit 1
fi

if [ -n "$(git ls-files --others --exclude-standard)" ]; then
  echo "Error: Untracked files present. Clean them before releasing."
  exit 1
fi

# Check required env vars
if [ -z "$DEVELOPER_ID" ]; then echo "Error: Set DEVELOPER_ID to your Developer ID Application certificate name"; exit 1; fi
if [ -z "$APPLE_ID" ]; then echo "Error: Set APPLE_ID to your Apple ID email"; exit 1; fi
if [ -z "$TEAM_ID" ]; then echo "Error: Set TEAM_ID to your Apple Team ID"; exit 1; fi
if [ -z "$APP_PASSWORD" ]; then echo "Error: Set APP_PASSWORD to your app-specific password"; exit 1; fi

echo "🚀 Releasing Voicey v$VERSION"
echo ""

# Bump version in all plists
echo "🔢 Bumping version..."
"$(dirname "$0")/bump-version.sh" "$VERSION"
echo ""

# Clean and build
echo "📦 Building..."
make clean
VOICEY_DIRECT=1 swift build -c release -Xswiftc -DVOICEY_DIRECT_DISTRIBUTION
make bundle-direct

# Sign (inside-out for Sparkle)
echo "🔏 Signing..."
SPARKLE_FW="Voicey.app/Contents/Frameworks/Sparkle.framework/Versions/B"
CODESIGN_TARGET_METALLIB="Voicey.app/Contents/MacOS/mlx.metallib"
CODESIGN="codesign --force --sign \"$DEVELOPER_ID\" --options runtime --timestamp"

eval $CODESIGN "$SPARKLE_FW/XPCServices/Downloader.xpc"
eval $CODESIGN "$SPARKLE_FW/XPCServices/Installer.xpc"
eval $CODESIGN "$SPARKLE_FW/Autoupdate"
eval $CODESIGN "$SPARKLE_FW/Updater.app"
eval $CODESIGN "Voicey.app/Contents/Frameworks/Sparkle.framework"
eval $CODESIGN "$CODESIGN_TARGET_METALLIB"
eval $CODESIGN --entitlements VoiceyDirect.entitlements Voicey.app

echo "✅ Verifying signature..."
codesign --verify --deep --strict Voicey.app

# Notarize
echo "📤 Notarizing..."
ditto -c -k --keepParent Voicey.app Voicey-notarize.zip
xcrun notarytool submit Voicey-notarize.zip \
  --apple-id "$APPLE_ID" \
  --team-id "$TEAM_ID" \
  --password "$APP_PASSWORD" \
  --wait
rm Voicey-notarize.zip

echo "📎 Stapling..."
xcrun stapler staple Voicey.app

# Create artifacts
echo "📁 Creating release artifacts..."
ditto -c -k --keepParent Voicey.app "Voicey-$VERSION.zip"

DMG_PATH="Voicey-$VERSION.dmg"
if [ "${SKIP_DMG:-}" = "1" ]; then
  echo "⏭️  SKIP_DMG=1 set; skipping DMG creation/notarization."
else
  DMG_STAGING_DIR="$(mktemp -d -t voicey-dmg-staging)"
  trap 'rm -rf "$DMG_STAGING_DIR"' EXIT
  cp -R "Voicey.app" "$DMG_STAGING_DIR/"
  # Remove provenance only: Metal libraries store their code signature in xattrs,
  # so stripping all attributes breaks notarization, but leaving provenance intact
  # causes hdiutil to fail while populating the image on this machine.
  xattr -rd com.apple.provenance "$DMG_STAGING_DIR/Voicey.app" 2>/dev/null || true
  ln -s "/Applications" "$DMG_STAGING_DIR/Applications"

  # Use APFS for the DMG filesystem (minimum supported macOS is 14.0).
  if ! hdiutil create -volname "Voicey Release" -srcfolder "$DMG_STAGING_DIR" -ov -format UDZO -fs APFS "$DMG_PATH"; then
    echo ""
    echo "❌ DMG creation failed."
    echo "   You can retry with DMG disabled:"
    echo "     SKIP_DMG=1 $0 $VERSION"
    exit 1
  fi

  rm -rf "$DMG_STAGING_DIR"
  trap - EXIT

  # Notarize DMG
  echo "📤 Notarizing DMG..."
  xcrun notarytool submit "$DMG_PATH" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID" \
    --password "$APP_PASSWORD" \
    --wait
  xcrun stapler staple "$DMG_PATH"
fi

VOICEY_DIRECT=1 swift package resolve

VERSION_FILES=(Info.plist Info.direct.plist project.yml)
if ! git diff --quiet -- "${VERSION_FILES[@]}"; then
  echo "📝 Committing version bump..."
  git add "${VERSION_FILES[@]}"
  git commit -m "Release v$VERSION"
fi

TAG="v$VERSION"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  TAG_TARGET="$(git rev-list -n 1 "$TAG")"
  HEAD_SHA="$(git rev-parse HEAD)"
  if [ "$TAG_TARGET" != "$HEAD_SHA" ]; then
    echo "Error: Tag $TAG already exists and does not point at HEAD."
    exit 1
  fi
  echo "🏷️ Tag $TAG already exists at HEAD; reusing."
else
  echo "🏷️ Creating tag $TAG..."
  git tag -a "$TAG" -m "Release v$VERSION"
fi

echo "⬆️ Pushing release commit and tag..."
git push "$PUSH_REMOTE" HEAD
git push "$PUSH_REMOTE" "$TAG"

# Create GitHub release if it doesn't already exist
if gh release view "$TAG" >/dev/null 2>&1; then
  echo "🐙 GitHub release $TAG already exists; skipping publish."
else
  echo "🐙 Creating GitHub release..."
  ASSETS=("Voicey-$VERSION.zip")
  if [ "${SKIP_DMG:-}" != "1" ] && [ -f "$DMG_PATH" ]; then
    ASSETS+=("$DMG_PATH")
  fi
  gh release create "$TAG" \
    --title "Voicey $VERSION" \
    --generate-notes \
    "${ASSETS[@]}"
fi

# Resolve signature from the published ZIP so appcast always matches GitHub asset bytes.
DOWNLOAD_URL="https://github.com/jonathanKingston/voicey/releases/download/v$VERSION/Voicey-$VERSION.zip"
PUBLISHED_ZIP="$(mktemp -t voicey-published-zip)"
trap 'rm -f "$PUBLISHED_ZIP"' EXIT

echo "🔑 Signing published ZIP for appcast..."
curl -fsSL "$DOWNLOAD_URL" -o "$PUBLISHED_ZIP"
SPARKLE_SIGN=$(.build/artifacts/sparkle/Sparkle/bin/sign_update "$PUBLISHED_ZIP")
echo "$SPARKLE_SIGN"

SIGNATURE=$(echo "$SPARKLE_SIGN" | sed 's/.*sparkle:edSignature="\([^"]*\)".*/\1/')
LENGTH=$(stat -f%z "$PUBLISHED_ZIP")

rm -f "$PUBLISHED_ZIP"
trap - EXIT

# Update appcast
echo "📝 Updating appcast..."
PUB_DATE=$(date -R)

APPCAST="../Voicey.work/public/appcast.xml"
if [ -f "$APPCAST" ]; then
  # Insert new release item after the language tag.
  python3 - "$APPCAST" "$VERSION" "$PUB_DATE" "$DOWNLOAD_URL" "$LENGTH" "$SIGNATURE" <<'PY'
import re
import sys
from pathlib import Path

appcast_path = Path(sys.argv[1])
version = sys.argv[2]
pub_date = sys.argv[3]
download_url = sys.argv[4]
length = sys.argv[5]
signature = sys.argv[6]

marker = "    <language>en</language>"
new_item = f"""
    <item>
      <title>Version {version}</title>
      <pubDate>{pub_date}</pubDate>
      <sparkle:version>{version}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure
        url="{download_url}"
        length="{length}"
        type="application/octet-stream"
        sparkle:edSignature="{signature}"
      />
    </item>
"""

content = appcast_path.read_text(encoding="utf-8")
if marker not in content:
    raise SystemExit(f"Error: Could not find marker '{marker}' in {appcast_path}")

version_tag = f"<sparkle:version>{version}</sparkle:version>"
if version_tag in content:
    item_pattern = re.compile(
        r"<item>\s*.*?<sparkle:version>" + re.escape(version) + r"</sparkle:version>.*?</item>",
        re.DOTALL,
    )
    matches = item_pattern.findall(content)
    if len(matches) != 1:
        raise SystemExit(
            f"Error: Expected exactly one appcast item for version {version}, found {len(matches)}"
        )
    updated = item_pattern.sub(new_item.strip(), content, count=1)
else:
    updated = content.replace(marker, f"{marker}\n{new_item}", 1)

appcast_path.write_text(updated, encoding="utf-8")
PY
  echo "✅ Updated $APPCAST"
  echo ""
  echo "Don't forget to commit and push Voicey.work:"
  echo "  cd ../Voicey.work && git add -A && git commit -m 'Release v$VERSION' && git push"
else
  echo "⚠️  Appcast not found at $APPCAST"
  echo "Update the appcast manually with version $VERSION, length $LENGTH, and generated signature."
fi

echo ""
echo "🎉 Release v$VERSION complete!"
echo "   DMG: Voicey-$VERSION.dmg"
echo "   ZIP: Voicey-$VERSION.zip"
echo "   GitHub: https://github.com/jonathanKingston/voicey/releases/tag/v$VERSION"
