# Voicey Build Makefile

APP_NAME = Voicey
BUILD_DIR = .build
RELEASE_DIR = $(BUILD_DIR)/release
APP_BUNDLE = $(APP_NAME).app
CONTENTS_DIR = $(APP_BUNDLE)/Contents
MACOS_DIR = $(CONTENTS_DIR)/MacOS
RESOURCES_DIR = $(CONTENTS_DIR)/Resources

.PHONY: all build release clean run install logs logs-direct reset-permissions reset-permissions-direct reset-state-direct reset-all-direct reset-full

all: build

# Debug build
build:
	swift build

# Debug build (direct distribution features enabled)
build-direct:
	swift build -Xswiftc -DVOICEY_DIRECT_DISTRIBUTION

# Release build
release:
	swift build -c release

# Release build (direct distribution features enabled)
release-direct:
	swift build -c release -Xswiftc -DVOICEY_DIRECT_DISTRIBUTION

# Create app bundle from release build
bundle: release
	@echo "Creating app bundle..."
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(MACOS_DIR)
	@mkdir -p $(RESOURCES_DIR)
	@cp $(RELEASE_DIR)/Voicey $(MACOS_DIR)/$(APP_NAME)
	@cp Info.plist $(CONTENTS_DIR)/
	@if [ -f Voicey.entitlements ]; then cp Voicey.entitlements $(CONTENTS_DIR)/; fi
	@if [ -d Resources ] && [ -n "$$(ls -A Resources 2>/dev/null)" ]; then cp -R Resources/* $(RESOURCES_DIR)/; fi
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
	@cp Info.plist $(CONTENTS_DIR)/
	@if [ -f Voicey.entitlements ]; then cp Voicey.entitlements $(CONTENTS_DIR)/; fi
	@if [ -d Resources ] && [ -n "$$(ls -A Resources 2>/dev/null)" ]; then cp -R Resources/* $(RESOURCES_DIR)/; fi
	@echo "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" > $(CONTENTS_DIR)/PkgInfo
	@echo "APPL????" >> $(CONTENTS_DIR)/PkgInfo
	@echo "Debug app bundle created: $(APP_BUNDLE)"

# Create app bundle with direct-distribution features (auto-paste)
bundle-direct: release-direct
	@echo "Creating app bundle (direct distribution)..."
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(MACOS_DIR)
	@mkdir -p $(RESOURCES_DIR)
	@cp $(RELEASE_DIR)/Voicey $(MACOS_DIR)/$(APP_NAME)
	@cp Info.direct.plist $(CONTENTS_DIR)/Info.plist
	@if [ -f VoiceyDirect.entitlements ]; then cp VoiceyDirect.entitlements $(CONTENTS_DIR)/Voicey.entitlements; fi
	@if [ -d Resources ] && [ -n "$$(ls -A Resources 2>/dev/null)" ]; then cp -R Resources/* $(RESOURCES_DIR)/; fi
	@echo "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" > $(CONTENTS_DIR)/PkgInfo
	@echo "APPL????" >> $(CONTENTS_DIR)/PkgInfo
	@echo "App bundle created: $(APP_BUNDLE)"

# Sign the app for development (ad-hoc)
sign: bundle
	@echo "Signing app (ad-hoc)..."
	@codesign --force --deep --sign - $(APP_BUNDLE)
	@echo "App signed"

# Sign for App Store submission (requires Apple Developer certificate)
# Usage: make sign-appstore IDENTITY="3rd Party Mac Developer Application: Your Name (TEAM_ID)"
IDENTITY ?= -
sign-appstore: bundle
	@echo "Signing app for App Store..."
	@codesign --force --deep \
		--sign "$(IDENTITY)" \
		--entitlements Voicey.entitlements \
		$(APP_BUNDLE)
	@echo "App signed for App Store"

# Create installer package for App Store
# Usage: make package-appstore IDENTITY="..." INSTALLER_IDENTITY="3rd Party Mac Developer Installer: Your Name (TEAM_ID)"
INSTALLER_IDENTITY ?= -
package-appstore: sign-appstore
	@echo "Creating installer package..."
	@productbuild --component $(APP_BUNDLE) /Applications \
		--sign "$(INSTALLER_IDENTITY)" \
		Voicey.pkg
	@echo "Installer package created: Voicey.pkg"

# Sign for direct distribution (notarization)
# Usage: make sign-direct DEVELOPER_ID="Developer ID Application: Your Name (TEAM_ID)"
DEVELOPER_ID ?= -
sign-direct: bundle-direct
	@echo "Signing app for direct distribution..."
	@codesign --force --deep \
		--sign "$(DEVELOPER_ID)" \
		--entitlements VoiceyDirect.entitlements \
		--options runtime \
		$(APP_BUNDLE)
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
	@hdiutil create -volname "Voicey" -srcfolder $(APP_BUNDLE) -ov -format UDZO Voicey.dmg
	@xcrun notarytool submit Voicey.dmg \
		--apple-id "$(APPLE_ID)" \
		--team-id "$(TEAM_ID)" \
		--password "$(APP_PASSWORD)" \
		--wait
	@xcrun stapler staple Voicey.dmg
	@echo "DMG created and notarized: Voicey.dmg"

# Clean build artifacts
clean:
	swift package clean
	rm -rf $(APP_BUNDLE)
	rm -rf $(BUILD_DIR)

# Run debug build
run: build
	$(BUILD_DIR)/debug/$(APP_NAME)

# Run as an app bundle (recommended for testing permissions like Accessibility)
run-bundle: bundle
	@open -n $(APP_BUNDLE)

# Run the debug app bundle
run-bundle-debug: bundle-debug
	@open -n $(APP_BUNDLE)

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
	log stream --predicate 'subsystem == "work.voicey.Voicey"' --level debug

# Stream debug logs for direct distribution build
logs-direct:
	log stream --predicate 'subsystem == "work.voicey.VoiceyDirect"' --level debug

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
	@echo "  bundle            - Create app bundle from release build"
	@echo "  sign              - Sign the app bundle (ad-hoc)"
	@echo "  clean             - Clean build artifacts"
	@echo "  run               - Build and run debug version"
	@echo "  run-bundle        - Build and run as app bundle"
	@echo "  logs              - Stream debug logs (run in separate terminal)"
	@echo "  install           - Install to /Applications"
	@echo "  xcode             - Generate and open Xcode project (requires xcodegen)"
	@echo "  xcode-generate    - Generate Xcode project without opening"
	@echo "  xcode-package     - Open Package.swift directly in Xcode"
	@echo ""
	@echo "App Store Distribution:"
	@echo "  sign-appstore     - Sign for App Store (requires IDENTITY)"
	@echo "  package-appstore  - Create .pkg for App Store upload"
	@echo "  icon              - Generate AppIcon.icns from SOURCE image"
	@echo ""
	@echo "Direct Distribution:"
	@echo "  bundle-direct     - Create bundle with auto-paste enabled"
	@echo "  sign-direct       - Sign for notarization (requires DEVELOPER_ID)"
	@echo "  notarize          - Notarize the app (requires APPLE_ID, TEAM_ID, APP_PASSWORD)"
	@echo "  dmg               - Create notarized DMG for distribution"
	@echo ""
	@echo "Reset & Debug:"
	@echo "  reset-state       - Reset app state (keeps models)"
	@echo "  reset-all         - Reset everything including models"
	@echo "  reset-permissions - Reset system permissions (mic, accessibility, login)"
	@echo "  reset-full        - Reset everything: state, models, and permissions"
	@echo "  show-state        - Show current app settings and models"
	@echo "  help              - Show this help"
