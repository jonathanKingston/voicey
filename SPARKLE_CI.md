# Sparkle Auto-Update CI Workflow

This document outlines the CI/CD workflow for publishing auto-updates via Sparkle for the direct distribution version of Voicey.

## Overview

The direct install version of Voicey uses [Sparkle](https://sparkle-project.org/) for automatic updates. Updates are served from `voicy.work` via an appcast XML file.

## Architecture

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   Voicey Repo   │────▶│   GitHub CI     │────▶│   voicy.work    │
│   (this repo)   │     │   (build/sign)  │     │   (website)     │
└─────────────────┘     └─────────────────┘     └─────────────────┘
        │                       │                       │
        │  Tag v1.2.3          │  Artifact             │  appcast.xml
        │                       │  Voicey-1.2.3.zip    │  /releases/
        └───────────────────────┴───────────────────────┘
```

## One-Time Setup

### 1. Generate Sparkle EdDSA Keys

```bash
# Generate the key pair (do this once, store securely)
make sparkle-generate-keys
```

This will output:
- **Private key**: Stored in macOS Keychain
- **Public key**: Add to `Info.direct.plist` under `SUPublicEDKey`

### 2. Export Private Key for CI

```bash
# Export the private key from Keychain
make sparkle-export-private-key
```

Copy the output and store it in GitHub Secrets as `SPARKLE_PRIVATE_KEY`.

### 3. Configure Secrets in GitHub

Add these secrets to your repository:

| Secret | Description |
|--------|-------------|
| `APPLE_DEVELOPER_ID` | Developer ID Application certificate name |
| `APPLE_ID` | Apple ID email for notarization |
| `APPLE_TEAM_ID` | Your Apple Developer Team ID |
| `APP_PASSWORD` | App-specific password for notarization |
| `SPARKLE_PRIVATE_KEY` | EdDSA private key for signing updates |

### 4. Update Info.direct.plist

Set the `SUPublicEDKey` in `Info.direct.plist`:

```xml
<key>SUPublicEDKey</key>
<string>YOUR_PUBLIC_KEY_HERE</string>
```

## Build Commands

### Direct Distribution (with Sparkle)

```bash
# Debug build
make build-direct

# Release build
make release-direct

# Create app bundle
make bundle-direct

# Full release (sign + notarize + DMG)
make dmg \
  DEVELOPER_ID="Developer ID Application: Your Name (TEAM_ID)" \
  APPLE_ID="your@email.com" \
  TEAM_ID="XXXXXXXXXX" \
  APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"

# Create Sparkle update archive
make sparkle-zip VERSION=1.0.0

# Sign an archive
make sparkle-sign FILE=Voicey-1.0.0.zip
```

### App Store (without Sparkle)

```bash
make build      # Debug
make release    # Release  
make bundle     # App bundle
```

### Verify Sparkle Linking

```bash
# Run this to ensure Sparkle is only in direct builds
make test-sparkle-linking
```

## Release Workflow

### Step 1: Update Version Numbers

1. Update `CFBundleShortVersionString` in `Info.direct.plist` (e.g., `1.2.3`)
2. Update `CFBundleVersion` in `Info.direct.plist` (increment build number)

### Step 2: Create a Git Tag

```bash
# Create and push a version tag
git tag -a v1.2.3 -m "Release version 1.2.3"
git push origin v1.2.3
```

### Step 3: CI Build Process

The CI workflow should:

1. **Build the app**
   ```bash
   make bundle-direct
   ```

2. **Sign for distribution**
   ```bash
   make sign-direct DEVELOPER_ID="$APPLE_DEVELOPER_ID"
   ```

3. **Notarize**
   ```bash
   make notarize \
     APPLE_ID="$APPLE_ID" \
     TEAM_ID="$APPLE_TEAM_ID" \
     APP_PASSWORD="$APP_PASSWORD"
   ```

4. **Create Sparkle update archive**
   ```bash
   make sparkle-zip VERSION=1.2.3
   ```

5. **Sign the archive with EdDSA**
   ```bash
   # Using Sparkle's sign_update tool
   SIGNATURE=$(.build/artifacts/sparkle/Sparkle/bin/sign_update Voicey-1.2.3.zip)
   # Or use the Makefile target:
   make sparkle-sign FILE=Voicey-1.2.3.zip
   ```

6. **Upload artifact**
   - Upload `Voicey-1.2.3.zip` to GitHub release artifacts
   - Or upload directly to `voicy.work/releases/`

### Step 4: Update Website Repo

The website repo (`voicy.work`) should be notified to update the appcast. This can be done via:

**Option A: GitHub Actions dispatch event**
```yaml
# In this repo's release workflow
- name: Trigger website update
  uses: peter-evans/repository-dispatch@v2
  with:
    token: ${{ secrets.WEBSITE_REPO_TOKEN }}
    repository: your-org/voicy-website
    event-type: new-release
    client-payload: '{"version": "${{ github.ref_name }}", "signature": "${{ steps.sign.outputs.signature }}"}'
```

**Option B: Direct commit to website repo**
```yaml
- name: Update appcast
  run: |
    # Clone website repo
    git clone https://github.com/your-org/voicy-website.git
    cd voicy-website
    
    # Update appcast.xml
    ./scripts/update-appcast.sh "$VERSION" "$SIGNATURE" "$DOWNLOAD_URL"
    
    # Commit and push
    git commit -am "Update appcast for v$VERSION"
    git push
```

## Appcast XML Format

The `appcast.xml` file on `voicy.work` should follow this format:

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Voicey Updates</title>
    <link>https://voicy.work/appcast.xml</link>
    <description>Voicey automatic updates</description>
    <language>en</language>
    
    <item>
      <title>Version 1.2.3</title>
      <pubDate>Mon, 20 Jan 2026 12:00:00 +0000</pubDate>
      <sparkle:version>1.2.3</sparkle:version>
      <sparkle:shortVersionString>1.2.3</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <enclosure 
        url="https://voicy.work/releases/Voicey-1.2.3.zip"
        length="12345678"
        type="application/octet-stream"
        sparkle:edSignature="YOUR_SIGNATURE_HERE"
      />
      <description>
        <![CDATA[
          <h2>What's New in 1.2.3</h2>
          <ul>
            <li>Bug fixes and improvements</li>
          </ul>
        ]]>
      </description>
    </item>
    
    <!-- Previous versions... -->
  </channel>
</rss>
```

## Website Repo Script Example

Create a script in your website repo to update the appcast:

```bash
#!/bin/bash
# scripts/update-appcast.sh

VERSION=$1
SIGNATURE=$2
DOWNLOAD_URL=$3
ZIP_FILE=$4

# Get file size
SIZE=$(stat -f%z "$ZIP_FILE" 2>/dev/null || stat -c%s "$ZIP_FILE")

# Get current date in RFC 2822 format
PUB_DATE=$(date -R)

# Generate the new item XML
cat > /tmp/new-item.xml << EOF
    <item>
      <title>Version $VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <enclosure 
        url="$DOWNLOAD_URL"
        length="$SIZE"
        type="application/octet-stream"
        sparkle:edSignature="$SIGNATURE"
      />
    </item>
EOF

# Insert new item at the top of the channel (after description)
# This is a simplified example - use proper XML tools for production
```

## Verification

After publishing:

1. **Check appcast is accessible**
   ```bash
   curl -I https://voicy.work/appcast.xml
   ```

2. **Verify signature**
   ```bash
   # Download and verify the update
   curl -O https://voicy.work/releases/Voicey-1.2.3.zip
   .build/artifacts/sparkle/Sparkle/bin/sign_update --verify Voicey-1.2.3.zip
   ```

3. **Test in app**
   - Launch Voicey (direct install version)
   - Go to Settings > Advanced > Check for Updates
   - Or wait for automatic check (default: 24 hours)

## Rollback

If a release needs to be rolled back:

1. Remove the problematic version from `appcast.xml`
2. Ensure the previous version's item is at the top
3. Commit and push the updated appcast

## Troubleshooting

### Update not showing
- Check `SUFeedURL` in `Info.direct.plist` matches appcast URL
- Verify appcast XML is valid
- Check minimum system version requirements

### Signature verification failed
- Ensure `SUPublicEDKey` in app matches the private key used for signing
- Re-generate signature with correct private key

### Notarization failed
- Check Apple Developer credentials
- Ensure app is properly code signed before notarization
- Review notarization log for specific errors

## Security Notes

1. **Never commit private keys** - Use GitHub Secrets or other secure storage
2. **Serve appcast over HTTPS** - Required for security
3. **Sign all updates** - EdDSA signatures prevent tampering
4. **Notarize all releases** - Required for macOS Gatekeeper
