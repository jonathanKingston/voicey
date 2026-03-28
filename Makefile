# Voicey Build Makefile

APP_NAME = Voicey
BUILD_DIR = .build
RELEASE_DIR = $(BUILD_DIR)/release
APP_BUNDLE = $(APP_NAME).app
CONTENTS_DIR = $(APP_BUNDLE)/Contents
MACOS_DIR = $(CONTENTS_DIR)/MacOS
RESOURCES_DIR = $(CONTENTS_DIR)/Resources
SPEECH_SWIFT_METALLIB_SCRIPT = $(BUILD_DIR)/checkouts/speech-swift/scripts/build_mlx_metallib.sh
MLX_METALLIB_DEBUG = $(BUILD_DIR)/debug/mlx.metallib
MLX_METALLIB_RELEASE = $(BUILD_DIR)/release/mlx.metallib
VOICEY_LOG_PREDICATE = subsystem == "work.voicey.Voicey" || subsystem == "work.voicey.VoiceyDirect"
RUN_WITH_LOG_STREAM = LOG_PID=""; trap 'if [ -n "$$LOG_PID" ]; then kill $$LOG_PID 2>/dev/null || true; wait $$LOG_PID 2>/dev/null || true; fi' EXIT INT TERM; echo "Streaming Voicey logs. Press Ctrl-C to stop."; log stream --style compact --predicate '$(VOICEY_LOG_PREDICATE)' --level debug & LOG_PID=$$!; sleep 1; open -n $(APP_BUNDLE); wait $$LOG_PID

.PHONY: all build build-release release release-direct ship-release clean run run-binary run-appstore run-appstore-binary install logs logs-direct reset-permissions reset-permissions-direct reset-state-direct reset-all-direct reset-full

all: build

# Debug build
build:
	swift build
	BUILD_DIR="$(CURDIR)/$(BUILD_DIR)" "$(SPEECH_SWIFT_METALLIB_SCRIPT)" debug

# Debug build (direct distribution features enabled, includes Sparkle)
build-direct:
	VOICEY_DIRECT=1 swift build -Xswiftc -DVOICEY_DIRECT_DISTRIBUTION
	BUILD_DIR="$(CURDIR)/$(BUILD_DIR)" "$(SPEECH_SWIFT_METALLIB_SCRIPT)" debug

# Release build (compile only)
build-release:
	swift build -c release
	BUILD_DIR="$(CURDIR)/$(BUILD_DIR)" "$(SPEECH_SWIFT_METALLIB_SCRIPT)" release

# Backwards-compatible release build alias
release: build-release

# Release build (direct distribution features enabled, includes Sparkle)
release-direct:
	VOICEY_DIRECT=1 swift build -c release -Xswiftc -DVOICEY_DIRECT_DISTRIBUTION
	BUILD_DIR="$(CURDIR)/$(BUILD_DIR)" "$(SPEECH_SWIFT_METALLIB_SCRIPT)" release

# Create app bundle from release build
bundle: build-release
	@echo "Creating app bundle..."
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(MACOS_DIR)
	@mkdir -p $(RESOURCES_DIR)
	@cp $(RELEASE_DIR)/Voicey $(MACOS_DIR)/$(APP_NAME)
	@cp $(MLX_METALLIB_RELEASE) $(MACOS_DIR)/mlx.metallib
	@cp Info.plist $(CONTENTS_DIR)/
	@if [ -f Voicey.entitlements ]; then cp Voicey.entitlements $(CONTENTS_DIR)/; fi
	@if [ -d Resources ] && [ -n "$$(ls -A Resources 2>/dev/null)" ]; then cp -R Resources/* $(RESOURCES_DIR)/; fi
	@cp -R $(RELEASE_DIR)/Voicey_Voicey.bundle $(RESOURCES_DIR)/
	@echo "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" > $(CONTENTS_DIR)/PkgInfo
	@echo "APPL????" >> $(CONTENTS_DIR)/PkgInfo
	@echo "App bundle created: $(APP_BUNDLE)"

# Create app bundle from debug build (recommended for testing permissions during development)
bundle-debug: build
	@echo "Creating debug app bundle..."
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(MACOS_DIR)
	@mkdir -p $(RESOURCES_DIR)
	@cp $(BUILD_DIR)/debug/Voicey $(MACOS_DIR)/$(APP_NAME)
	@cp $(MLX_METALLIB_DEBUG) $(MACOS_DIR)/mlx.metallib
	@cp Info.plist $(CONTENTS_DIR)/
	@if [ -f Voicey.entitlements ]; then cp Voicey.entitlements $(CONTENTS_DIR)/; fi
	@if [ -d Resources ] && [ -n "$$(ls -A Resources 2>/dev/null)" ]; then cp -R Resources/* $(RESOURCES_DIR)/; fi
	@cp -R $(BUILD_DIR)/debug/Voicey_Voicey.bundle $(RESOURCES_DIR)/
	@echo "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" > $(CONTENTS_DIR)/PkgInfo
	@echo "APPL????" >> $(CONTENTS_DIR)/PkgInfo
	@echo "Debug app bundle created: $(APP_BUNDLE)"

# Create debug app bundle with direct-distribution features
bundle-debug-direct: build-direct
	@echo "Creating debug app bundle (direct distribution)..."
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(MACOS_DIR)
	@mkdir -p $(RESOURCES_DIR)
	@mkdir -p $(FRAMEWORKS_DIR)
	@cp $(BUILD_DIR)/debug/Voicey $(MACOS_DIR)/$(APP_NAME)
	@cp $(MLX_METALLIB_DEBUG) $(MACOS_DIR)/mlx.metallib
	@cp Info.direct.plist $(CONTENTS_DIR)/Info.plist
	@if [ -d Resources ] && [ -n "$$(ls -A Resources 2>/dev/null)" ]; then cp -R Resources/* $(RESOURCES_DIR)/; fi
	@cp -R $(BUILD_DIR)/debug/Voicey_Voicey.bundle $(RESOURCES_DIR)/
	@echo "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" > $(CONTENTS_DIR)/PkgInfo
	@echo "APPL????" >> $(CONTENTS_DIR)/PkgInfo
	@# Copy Sparkle.framework for auto-updates
	@if [ ! -d "$(SPARKLE_FRAMEWORK_DEBUG)" ]; then \
		echo "Error: Sparkle.framework not found at $(SPARKLE_FRAMEWORK_DEBUG)"; \
		exit 1; \
	fi
	@cp -R "$(SPARKLE_FRAMEWORK_DEBUG)" "$(FRAMEWORKS_DIR)/"
	@echo "Sparkle.framework copied to bundle"
	@echo "Adding @rpath for Sparkle.framework..."
	@install_name_tool -add_rpath "@executable_path/../Frameworks" "$(MACOS_DIR)/$(APP_NAME)"
	@echo "Debug app bundle created: $(APP_BUNDLE)"

# Create app bundle with direct-distribution features (Sparkle auto-updates)
FRAMEWORKS_DIR = $(CONTENTS_DIR)/Frameworks
SPARKLE_FRAMEWORK_DEBUG = $(BUILD_DIR)/debug/Sparkle.framework
SPARKLE_FRAMEWORK_RELEASE = $(RELEASE_DIR)/Sparkle.framework

bundle-direct: release-direct
	@echo "Creating app bundle (direct distribution)..."
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(MACOS_DIR)
	@mkdir -p $(RESOURCES_DIR)
	@mkdir -p $(FRAMEWORKS_DIR)
	@cp $(RELEASE_DIR)/Voicey $(MACOS_DIR)/$(APP_NAME)
	@cp $(MLX_METALLIB_RELEASE) $(MACOS_DIR)/mlx.metallib
	@cp Info.direct.plist $(CONTENTS_DIR)/Info.plist
	@if [ -d Resources ] && [ -n "$$(ls -A Resources 2>/dev/null)" ]; then cp -R Resources/* $(RESOURCES_DIR)/; fi
	@cp -R $(RELEASE_DIR)/Voicey_Voicey.bundle $(RESOURCES_DIR)/
	@echo "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" > $(CONTENTS_DIR)/PkgInfo
	@echo "APPL????" >> $(CONTENTS_DIR)/PkgInfo
	@# Copy Sparkle.framework for auto-updates
	@if [ ! -d "$(SPARKLE_FRAMEWORK_RELEASE)" ]; then \
		echo "Error: Sparkle.framework not found at $(SPARKLE_FRAMEWORK_RELEASE)"; \
		exit 1; \
	fi
	@cp -R "$(SPARKLE_FRAMEWORK_RELEASE)" "$(FRAMEWORKS_DIR)/"
	@echo "Sparkle.framework copied to bundle"
	@echo "Adding @rpath for Sparkle.framework..."
	@install_name_tool -add_rpath "@executable_path/../Frameworks" "$(MACOS_DIR)/$(APP_NAME)"
	@echo "App bundle created: $(APP_BUNDLE)"

# Sign the app for development (ad-hoc)
sign: bundle
	@echo "Signing app (ad-hoc)..."
	@codesign --force --deep --sign - $(APP_BUNDLE)
	@echo "App signed"

# Sign for App Store submission (requires Apple Developer certificate)
# Auto-detects certificate hash if not provided. Override with: make sign-appstore IDENTITY="..." or IDENTITY=HASH
IDENTITY ?= $(shell security find-identity -v -p codesigning | grep "Apple Distribution" | head -1 | awk '{print $$2}')
sign-appstore: bundle
	@if [ "$(IDENTITY)" = "" ] || [ "$(IDENTITY)" = "-" ]; then \
		echo "Error: No valid 'Apple Distribution' certificate found."; \
		echo "Install one via Xcode or Apple Developer portal, or specify manually:"; \
		echo "  make sign-appstore IDENTITY=\"Apple Distribution: Your Name (TEAM_ID)\""; \
		exit 1; \
	fi
	@echo "Signing app for App Store..."
	@codesign --force --deep \
		--sign "$(IDENTITY)" \
		--entitlements Voicey.entitlements \
		$(APP_BUNDLE)
	@echo "App signed for App Store"

# Create installer package for App Store
# Auto-detects certificate hash if not provided. Override with: make package-appstore INSTALLER_IDENTITY="..." or INSTALLER_IDENTITY=HASH
INSTALLER_IDENTITY ?= $(shell security find-identity -v -p basic | grep "3rd Party Mac Developer Installer" | head -1 | awk '{print $$2}')
package-appstore: sign-appstore
	@if [ "$(INSTALLER_IDENTITY)" = "" ] || [ "$(INSTALLER_IDENTITY)" = "-" ]; then \
		echo "Error: No valid '3rd Party Mac Developer Installer' certificate found."; \
		echo "Install one via Xcode or Apple Developer portal, or specify manually:"; \
		echo "  make package-appstore INSTALLER_IDENTITY=\"3rd Party Mac Developer Installer: Your Name (TEAM_ID)\""; \
		exit 1; \
	fi
	@echo "Creating installer package..."
	@productbuild --component $(APP_BUNDLE) /Applications \
		--sign "$(INSTALLER_IDENTITY)" \
		Voicey.pkg
	@echo "Installer package created: Voicey.pkg"

# Sign for direct distribution (notarization)
# Usage: make sign-direct DEVELOPER_ID="Developer ID Application: Your Name (TEAM_ID)"
DEVELOPER_ID ?= -
CODESIGN_OPTS = --force --sign "$(DEVELOPER_ID)" --options runtime --timestamp
SPARKLE_FW = $(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework

sign-direct: bundle-direct
	@echo "Signing app for direct distribution..."
	@echo "Signing Sparkle.framework components (inside-out)..."
	@# Sign XPC services first
	@codesign $(CODESIGN_OPTS) "$(SPARKLE_FW)/Versions/B/XPCServices/Downloader.xpc"
	@codesign $(CODESIGN_OPTS) "$(SPARKLE_FW)/Versions/B/XPCServices/Installer.xpc"
	@# Sign helper apps and tools
	@codesign $(CODESIGN_OPTS) "$(SPARKLE_FW)/Versions/B/Autoupdate"
	@codesign $(CODESIGN_OPTS) "$(SPARKLE_FW)/Versions/B/Updater.app"
	@# Sign the framework itself
	@codesign $(CODESIGN_OPTS) "$(SPARKLE_FW)"
	@echo "Signing main app..."
	@codesign $(CODESIGN_OPTS) --entitlements VoiceyDirect.entitlements $(APP_BUNDLE)
	@echo "App signed for direct distribution"

# Notarize for direct distribution
# Usage: make notarize APPLE_ID="your@email.com" TEAM_ID="XXXXXXXXXX" APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"
APPLE_ID ?=
TEAM_ID ?=
APP_PASSWORD ?=
notarize: sign-direct
	@echo "Creating ZIP for notarization..."
	@ditto -c -k --keepParent $(APP_BUNDLE) Voicey.zip
	@echo "Submitting for notarization..."
	@xcrun notarytool submit Voicey.zip \
		--apple-id "$(APPLE_ID)" \
		--team-id "$(TEAM_ID)" \
		--password "$(APP_PASSWORD)" \
		--wait
	@echo "Stapling notarization ticket..."
	@xcrun stapler staple $(APP_BUNDLE)
	@rm Voicey.zip
	@echo "Notarization complete"

# Create DMG for direct distribution
dmg: notarize
	@echo "Creating DMG..."
	@DMG_STAGING_DIR=$$(mktemp -d -t voicey-dmg-staging) && \
		cp -R "$(APP_BUNDLE)" "$$DMG_STAGING_DIR/" && \
		ln -s /Applications "$$DMG_STAGING_DIR/Applications" && \
		hdiutil create -volname "Voicey" -srcfolder "$$DMG_STAGING_DIR" -ov -format UDZO Voicey.dmg && \
		rm -rf "$$DMG_STAGING_DIR"
	@xcrun notarytool submit Voicey.dmg \
		--apple-id "$(APPLE_ID)" \
		--team-id "$(TEAM_ID)" \
		--password "$(APP_PASSWORD)" \
		--wait
	@xcrun stapler staple Voicey.dmg
	@echo "DMG created and notarized: Voicey.dmg"

# Sparkle tools location (after running VOICEY_DIRECT=1 swift package resolve)
SPARKLE_BIN = .build/artifacts/sparkle/Sparkle/bin

# Create ZIP for Sparkle updates (notarized app bundle)
sparkle-zip: notarize
	@echo "Creating Sparkle update archive..."
	@ditto -c -k --keepParent $(APP_BUNDLE) Voicey-$(VERSION).zip
	@echo "Update archive created: Voicey-$(VERSION).zip"
	@echo ""
	@echo "Next steps for Sparkle update:"
	@echo "1. Generate EdDSA signature: $(SPARKLE_BIN)/sign_update Voicey-$(VERSION).zip"
	@echo "2. Upload to voicy.work/releases/Voicey-$(VERSION).zip"
	@echo "3. Update appcast.xml with version, signature, and download URL"

# Sign a Sparkle update archive with EdDSA
# Usage: make sparkle-sign FILE=Voicey-1.0.0.zip
FILE ?=
sparkle-sign:
	@if [ -z "$(FILE)" ]; then echo "Usage: make sparkle-sign FILE=Voicey-X.Y.Z.zip"; exit 1; fi
	@if [ ! -f "$(SPARKLE_BIN)/sign_update" ]; then \
		echo "Sparkle tools not found. Run: VOICEY_DIRECT=1 swift package resolve"; \
		exit 1; \
	fi
	@$(SPARKLE_BIN)/sign_update "$(FILE)"

# Generate Sparkle EdDSA keys (one-time setup)
# Store the private key securely and add public key to Info.direct.plist SUPublicEDKey
sparkle-generate-keys:
	@echo "Generating Sparkle EdDSA keys..."
	@echo ""
	@if [ ! -f "$(SPARKLE_BIN)/generate_keys" ]; then \
		echo "Sparkle tools not found. Fetching..."; \
		VOICEY_DIRECT=1 swift package resolve; \
	fi
	@echo "⚠️  IMPORTANT: Save the private key securely (GitHub Secret, 1Password, etc.)"
	@echo "⚠️  The public key goes in Info.direct.plist as SUPublicEDKey"
	@echo ""
	@$(SPARKLE_BIN)/generate_keys

# Export the Sparkle private key from Keychain (for CI setup)
# Copy the output to GitHub Secrets as SPARKLE_PRIVATE_KEY
sparkle-export-private-key:
	@if [ ! -f "$(SPARKLE_BIN)/generate_keys" ]; then \
		echo "Sparkle tools not found. Run: VOICEY_DIRECT=1 swift package resolve"; \
		exit 1; \
	fi
	@echo "⚠️  Copy this private key to GitHub Secrets as SPARKLE_PRIVATE_KEY:"
	@echo ""
	@TMPFILE=$$(mktemp) && rm -f "$$TMPFILE" && $(SPARKLE_BIN)/generate_keys -x "$$TMPFILE" && cat "$$TMPFILE" && rm -f "$$TMPFILE"

# VERSION should be set when creating releases
VERSION ?= $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.direct.plist)

# Clean build artifacts
clean:
	swift package clean
	rm -rf $(APP_BUNDLE)
	rm -rf $(BUILD_DIR)

# Test that Sparkle is correctly linked only in direct distribution builds
test-sparkle-linking:
	@echo "🧪 Testing Sparkle linking configuration..."
	@echo ""
	@echo "Step 1: Building App Store version (should NOT have Sparkle)..."
	@rm -rf $(BUILD_DIR)
	@swift build -q 2>/dev/null
	@if otool -L $(BUILD_DIR)/debug/Voicey 2>/dev/null | grep -q Sparkle; then \
		echo "❌ FAIL: App Store build has Sparkle linked (it should NOT)"; \
		exit 1; \
	else \
		echo "✅ PASS: App Store build does NOT have Sparkle linked"; \
	fi
	@echo ""
	@echo "Step 2: Building Direct distribution version (should HAVE Sparkle)..."
	@rm -rf $(BUILD_DIR)
	@VOICEY_DIRECT=1 swift build -q -Xswiftc -DVOICEY_DIRECT_DISTRIBUTION 2>/dev/null
	@if otool -L $(BUILD_DIR)/debug/Voicey 2>/dev/null | grep -q Sparkle; then \
		echo "✅ PASS: Direct build HAS Sparkle linked"; \
	else \
		echo "❌ FAIL: Direct build does NOT have Sparkle linked (it should)"; \
		exit 1; \
	fi
	@echo ""
	@echo "🎉 All Sparkle linking tests passed!"

# Run debug bundle with direct-distribution flags (recommended default)
run: bundle-debug-direct
	@echo "Ad-hoc signing debug bundle for local testing..."
	@codesign --force --deep --sign - $(APP_BUNDLE)
	@$(RUN_WITH_LOG_STREAM)

# Run raw debug binary with direct-distribution flags
run-binary: build-direct
	$(BUILD_DIR)/debug/$(APP_NAME)

# Run debug bundle without direct-distribution flags
run-appstore: bundle-debug
	@$(RUN_WITH_LOG_STREAM)

# Run raw debug binary without direct-distribution flags
run-appstore-binary: build
	$(BUILD_DIR)/debug/$(APP_NAME)

# Run as an app bundle (recommended for testing permissions like Accessibility)
run-bundle: bundle
	@$(RUN_WITH_LOG_STREAM)

# Run the debug app bundle
run-bundle-debug: bundle-debug
	@$(RUN_WITH_LOG_STREAM)

# Run direct distribution bundle (with Sparkle, ad-hoc signed for testing)
run-bundle-direct: bundle-direct
	@echo "Ad-hoc signing for local testing..."
	@codesign --force --deep --sign - $(APP_BUNDLE)
	@$(RUN_WITH_LOG_STREAM)

# Install to Applications
install: sign
	@echo "Installing to /Applications..."
	@rm -rf /Applications/$(APP_BUNDLE)
	@cp -R $(APP_BUNDLE) /Applications/
	@echo "Installed to /Applications/$(APP_BUNDLE)"

# Xcode project generation (requires: brew install xcodegen)
xcode: xcode-generate
	@open Voicey.xcodeproj

xcode-generate:
	@if ! command -v xcodegen &> /dev/null; then \
		echo "XcodeGen not found. Install with: brew install xcodegen"; \
		exit 1; \
	fi
	@echo "Generating Xcode project from project.yml..."
	@xcodegen generate
	@echo "Xcode project generated: Voicey.xcodeproj"

# Open Package.swift directly (alternative to xcode project)
xcode-package:
	@echo "Opening Package.swift in Xcode..."
	open Package.swift

# Format code
format:
	swift-format -i -r Sources/

# Stream debug logs (run in separate terminal)
logs:
	log stream --style compact --predicate 'subsystem == "work.voicey.Voicey"' --level debug

# Stream debug logs for direct distribution build
logs-direct:
	log stream --style compact --predicate 'subsystem == "work.voicey.VoiceyDirect"' --level debug

# Reset app state (keeps downloaded models)
reset-state:
	@echo "Resetting app state (keeping models)..."
	@defaults delete work.voicey.Voicey 2>/dev/null || true
	@echo "Done. App will show onboarding on next launch."

# Reset app state for direct distribution (keeps downloaded models)
reset-state-direct:
	@echo "Resetting app state for direct distribution (keeping models)..."
	@defaults delete work.voicey.VoiceyDirect 2>/dev/null || true
	@echo "Done. App will show onboarding on next launch."

# Reset everything including models
reset-all:
	@echo "Resetting all app data..."
	@defaults delete work.voicey.Voicey 2>/dev/null || true
	@rm -rf ~/Library/Application\ Support/Voicey/Models
	@echo "Done. App will show onboarding and require model download."

# Reset everything for direct distribution including models
reset-all-direct:
	@echo "Resetting all app data for direct distribution..."
	@defaults delete work.voicey.VoiceyDirect 2>/dev/null || true
	@rm -rf ~/Library/Application\ Support/Voicey/Models
	@echo "Done. App will show onboarding and require model download."

# Reset system permissions (microphone, accessibility, login items)
reset-permissions:
	@echo "Resetting system permissions for Voicey..."
	@echo ""
	@echo "Resetting microphone permission..."
	@tccutil reset Microphone work.voicey.Voicey 2>/dev/null || echo "  (requires running as admin or SIP disabled)"
	@echo "Resetting accessibility permission (only needed for optional auto-paste)..."
	@tccutil reset Accessibility work.voicey.Voicey 2>/dev/null || echo "  (requires running as admin or SIP disabled)"
	@echo "Resetting login items..."
	@sfltool resetbtm 2>/dev/null || echo "  (requires admin privileges)"
	@echo ""
	@echo "Done. You may need to:"
	@echo "  - Re-grant microphone access in System Settings > Privacy & Security > Microphone"
	@echo "  - Re-grant accessibility in System Settings > Privacy & Security > Accessibility (if using auto-paste)"
	@echo "  - Re-enable 'Launch at Login' in app settings"

# Reset permissions for direct distribution build (includes accessibility)
reset-permissions-direct:
	@echo "Resetting system permissions for Voicey (direct distribution)..."
	@echo ""
	@echo "Resetting microphone permission..."
	@tccutil reset Microphone work.voicey.VoiceyDirect 2>/dev/null || echo "  (requires running as admin or SIP disabled)"
	@echo "Resetting accessibility permission..."
	@tccutil reset Accessibility work.voicey.VoiceyDirect 2>/dev/null || echo "  (requires running as admin or SIP disabled)"
	@echo "Resetting login items..."
	@sfltool resetbtm 2>/dev/null || echo "  (requires admin privileges)"
	@echo ""
	@echo "Done. You may need to:"
	@echo "  - Re-grant microphone access in System Settings > Privacy & Security > Microphone"
	@echo "  - Re-grant accessibility in System Settings > Privacy & Security > Accessibility"
	@echo "  - Re-enable 'Launch at Login' in app settings"

# Full reset: app state + models + permissions
reset-full: reset-all reset-permissions
	@echo ""
	@echo "Full reset complete."

# Show detected signing identities
show-identities:
	@echo "=== Detected Signing Identities ==="
	@echo ""
	@echo "App Store (Apple Distribution):"
	@security find-identity -v -p codesigning | grep "Apple Distribution" | while read line; do \
		HASH=$$(echo "$$line" | awk '{print $$2}'); \
		NAME=$$(echo "$$line" | sed 's/.*"\(.*\)".*/\1/'); \
		echo "  $$HASH  $$NAME"; \
	done || echo "  ❌ Not found"
	@echo ""
	@echo "Installer (3rd Party Mac Developer Installer):"
	@security find-identity -v -p basic | grep "3rd Party Mac Developer Installer" | while read line; do \
		HASH=$$(echo "$$line" | awk '{print $$2}'); \
		NAME=$$(echo "$$line" | sed 's/.*"\(.*\)".*/\1/'); \
		echo "  $$HASH  $$NAME"; \
	done || echo "  ❌ Not found"
	@echo ""
	@echo "Direct Distribution (Developer ID Application):"
	@security find-identity -v -p codesigning | grep "Developer ID Application" | while read line; do \
		HASH=$$(echo "$$line" | awk '{print $$2}'); \
		NAME=$$(echo "$$line" | sed 's/.*"\(.*\)".*/\1/'); \
		echo "  $$HASH  $$NAME"; \
	done || echo "  ❌ Not found"
	@echo ""
	@echo "To use a specific cert by hash: make package-appstore IDENTITY=HASH_HERE"

# Show current app state
show-state:
	@echo "=== App Settings (App Store) ==="
	@defaults read work.voicey.Voicey 2>/dev/null || echo "(no settings saved)"
	@echo ""
	@echo "=== App Settings (Direct) ==="
	@defaults read work.voicey.VoiceyDirect 2>/dev/null || echo "(no settings saved)"
	@echo ""
	@echo "=== Downloaded Models ==="
	@ls -la ~/Library/Application\ Support/Voicey/Models/models/argmaxinc/whisperkit-coreml/ 2>/dev/null || echo "(no models downloaded)"

# Generate app icon from a 1024x1024 source image
# Usage: make icon SOURCE=path/to/icon_1024.png
SOURCE ?= icon_1024.png
icon:
	@echo "Generating app icon from $(SOURCE)..."
	@mkdir -p AppIcon.iconset
	@mkdir -p Resources
	@sips -z 16 16     "$(SOURCE)" --out AppIcon.iconset/icon_16x16.png
	@sips -z 32 32     "$(SOURCE)" --out AppIcon.iconset/icon_16x16@2x.png
	@sips -z 32 32     "$(SOURCE)" --out AppIcon.iconset/icon_32x32.png
	@sips -z 64 64     "$(SOURCE)" --out AppIcon.iconset/icon_32x32@2x.png
	@sips -z 128 128   "$(SOURCE)" --out AppIcon.iconset/icon_128x128.png
	@sips -z 256 256   "$(SOURCE)" --out AppIcon.iconset/icon_128x128@2x.png
	@sips -z 256 256   "$(SOURCE)" --out AppIcon.iconset/icon_256x256.png
	@sips -z 512 512   "$(SOURCE)" --out AppIcon.iconset/icon_256x256@2x.png
	@sips -z 512 512   "$(SOURCE)" --out AppIcon.iconset/icon_512x512.png
	@cp "$(SOURCE)"    AppIcon.iconset/icon_512x512@2x.png
	@iconutil -c icns AppIcon.iconset
	@cp AppIcon.icns Resources/
	@rm -rf AppIcon.iconset AppIcon.icns
	@echo "App icon saved to Resources/AppIcon.icns (will be included in bundle builds)"

# Help
help:
	@echo "Voicey Build System"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Development:"
	@echo "  build             - Build debug version (default)"
	@echo "  release           - Build release version"
	@echo "  ship-release      - Full signed/notarized release workflow"
	@echo "  bundle            - Create app bundle from release build"
	@echo "  sign              - Sign the app bundle (ad-hoc)"
	@echo "  clean             - Clean build artifacts"
	@echo "  run               - Build and run debug app bundle (default)"
	@echo "  run-binary        - Build and run raw debug binary"
	@echo "  run-bundle        - Build and run as app bundle"
	@echo "  run-appstore      - Build and run App Store-style debug app bundle"
	@echo "  run-appstore-binary - Build and run raw App Store-style debug binary"
	@echo "  logs              - Stream debug logs (run in separate terminal)"
	@echo "  install           - Install to /Applications"
	@echo "  xcode             - Generate and open Xcode project (requires xcodegen)"
	@echo "  xcode-generate    - Generate Xcode project without opening"
	@echo "  xcode-package     - Open Package.swift directly in Xcode"
	@echo ""
	@echo "App Store Distribution:"
	@echo "  sign-appstore     - Sign for App Store (auto-detects certificate)"
	@echo "  package-appstore  - Create .pkg for App Store upload (auto-detects certs)"
	@echo "  icon              - Generate AppIcon.icns from SOURCE image"
	@echo "  show-identities   - Show detected signing certificates"
	@echo ""
	@echo "Direct Distribution:"
	@echo "  bundle-direct     - Create bundle with clipboard-only mode"
	@echo "  sign-direct       - Sign for notarization (requires DEVELOPER_ID)"
	@echo "  notarize          - Notarize the app (requires APPLE_ID, TEAM_ID, APP_PASSWORD)"
	@echo "  dmg               - Create notarized DMG for distribution"
	@echo "  sparkle-zip       - Create ZIP for Sparkle auto-updates"
	@echo "  sparkle-sign      - Sign a ZIP with EdDSA (FILE=Voicey-X.Y.Z.zip)"
	@echo "  sparkle-generate-keys - Generate EdDSA keys for Sparkle signing"
	@echo ""
	@echo "Reset & Debug:"
	@echo "  reset-state       - Reset app state (keeps models)"
	@echo "  reset-all         - Reset everything including models"
	@echo "  reset-permissions - Reset system permissions (mic, accessibility, login)"
	@echo "  reset-full        - Reset everything: state, models, and permissions"
	@echo "  show-state        - Show current app settings and models"
	@echo "  help              - Show this help"
	@echo ""
	@echo "Release:"
	@echo "  ship-release VERSION=X.Y.Z - Full release (build, sign, notarize, publish)"
	@echo ""
	@echo "Testing:"
	@echo "  test-sparkle-linking - Verify Sparkle is only linked in direct builds"

# Full release process
# Usage: make ship-release VERSION=1.2.0
ship-release:
	@DEVELOPER_ID="$(DEVELOPER_ID)" APPLE_ID="$(APPLE_ID)" TEAM_ID="$(TEAM_ID)" APP_PASSWORD="$(APP_PASSWORD)" ./scripts/release.sh $(VERSION)
