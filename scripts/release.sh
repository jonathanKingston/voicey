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

# Check required env vars
if [ -z "$DEVELOPER_ID" ]; then echo "Error: Set DEVELOPER_ID to your Developer ID Application certificate name"; exit 1; fi
if [ -z "$APPLE_ID" ]; then echo "Error: Set APPLE_ID to your Apple ID email"; exit 1; fi
if [ -z "$TEAM_ID" ]; then echo "Error: Set TEAM_ID to your Apple Team ID"; exit 1; fi
if [ -z "$APP_PASSWORD" ]; then echo "Error: Set APP_PASSWORD to your app-specific password"; exit 1; fi

echo "🚀 Releasing Voicey v$VERSION"
echo ""

# Clean and build
echo "📦 Building..."
make clean
VOICEY_DIRECT=1 swift build -c release -Xswiftc -DVOICEY_DIRECT_DISTRIBUTION
make bundle-direct

# Sign (inside-out for Sparkle)
echo "🔏 Signing..."
SPARKLE_FW="Voicey.app/Contents/Frameworks/Sparkle.framework/Versions/B"
CODESIGN="codesign --force --sign \"$DEVELOPER_ID\" --options runtime --timestamp"

eval $CODESIGN "$SPARKLE_FW/XPCServices/Downloader.xpc"
eval $CODESIGN "$SPARKLE_FW/XPCServices/Installer.xpc"
eval $CODESIGN "$SPARKLE_FW/Autoupdate"
eval $CODESIGN "$SPARKLE_FW/Updater.app"
eval $CODESIGN "Voicey.app/Contents/Frameworks/Sparkle.framework"
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
DMG_STAGING_DIR="$(mktemp -d -t voicey-dmg-staging)"
trap 'rm -rf "$DMG_STAGING_DIR"' EXIT
cp -R "Voicey.app" "$DMG_STAGING_DIR/"
ln -s "/Applications" "$DMG_STAGING_DIR/Applications"
hdiutil create -volname "Voicey" -srcfolder "$DMG_STAGING_DIR" -ov -format UDZO "Voicey-$VERSION.dmg"
rm -rf "$DMG_STAGING_DIR"
trap - EXIT

# Notarize DMG
echo "📤 Notarizing DMG..."
xcrun notarytool submit "Voicey-$VERSION.dmg" \
  --apple-id "$APPLE_ID" \
  --team-id "$TEAM_ID" \
  --password "$APP_PASSWORD" \
  --wait
xcrun stapler staple "Voicey-$VERSION.dmg"

# Sign with Sparkle EdDSA
echo "🔑 Signing with Sparkle EdDSA..."
VOICEY_DIRECT=1 swift package resolve
SPARKLE_SIGN=$(.build/artifacts/sparkle/Sparkle/bin/sign_update "Voicey-$VERSION.zip")
echo "$SPARKLE_SIGN"

SIGNATURE=$(echo "$SPARKLE_SIGN" | sed 's/.*sparkle:edSignature="\([^"]*\)".*/\1/')
LENGTH=$(stat -f%z "Voicey-$VERSION.zip")

# Create GitHub release
echo "🐙 Creating GitHub release..."
gh release create "v$VERSION" \
  --title "Voicey $VERSION" \
  --generate-notes \
  "Voicey-$VERSION.dmg" \
  "Voicey-$VERSION.zip"

# Update appcast
echo "📝 Updating appcast..."
PUB_DATE=$(date -R)
DOWNLOAD_URL="https://github.com/jonathanKingston/voicey/releases/download/v$VERSION/Voicey-$VERSION.zip"

NEW_ITEM="    <item>
      <title>Version $VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <enclosure
        url=\"$DOWNLOAD_URL\"
        length=\"$LENGTH\"
        type=\"application/octet-stream\"
        sparkle:edSignature=\"$SIGNATURE\"
      />
    </item>"

APPCAST="../Voicey.work/public/appcast.xml"
if [ -f "$APPCAST" ]; then
  # Insert after <language>en</language>
  sed -i '' "/<language>en<\/language>/a\\
\\
$NEW_ITEM
" "$APPCAST"
  echo "✅ Updated $APPCAST"
  echo ""
  echo "Don't forget to commit and push Voicey.work:"
  echo "  cd ../Voicey.work && git add -A && git commit -m 'Release v$VERSION' && git push"
else
  echo "⚠️  Appcast not found at $APPCAST"
  echo "Add this item manually:"
  echo "$NEW_ITEM"
fi

echo ""
echo "🎉 Release v$VERSION complete!"
echo "   DMG: Voicey-$VERSION.dmg"
echo "   ZIP: Voicey-$VERSION.zip"
echo "   GitHub: https://github.com/jonathanKingston/voicey/releases/tag/v$VERSION"
