# Voicey Build Makefile

APP_NAME = Voicey
BUILD_DIR = .build
RELEASE_DIR = $(BUILD_DIR)/release
APP_BUNDLE = $(APP_NAME).app
CONTENTS_DIR = $(APP_BUNDLE)/Contents
MACOS_DIR = $(CONTENTS_DIR)/MacOS
RESOURCES_DIR = $(CONTENTS_DIR)/Resources

.PHONY: all build release clean run install logs

all: build

# Debug build
build:
	swift build

# Release build
release:
	swift build -c release

# Create app bundle from release build
bundle: release
	@echo "Creating app bundle..."
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(MACOS_DIR)
	@mkdir -p $(RESOURCES_DIR)
	@cp $(RELEASE_DIR)/Voicey $(MACOS_DIR)/$(APP_NAME)
	@cp Info.plist $(CONTENTS_DIR)/
	@if [ -f Voicey.entitlements ]; then cp Voicey.entitlements $(CONTENTS_DIR)/; fi
	@echo "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" > $(CONTENTS_DIR)/PkgInfo
	@echo "APPL????" >> $(CONTENTS_DIR)/PkgInfo
	@echo "App bundle created: $(APP_BUNDLE)"

# Sign the app (requires valid developer identity)
sign: bundle
	@echo "Signing app..."
	@codesign --force --deep --sign - $(APP_BUNDLE)
	@echo "App signed"

# Clean build artifacts
clean:
	swift package clean
	rm -rf $(APP_BUNDLE)
	rm -rf $(BUILD_DIR)

# Run debug build
run: build
	$(BUILD_DIR)/debug/$(APP_NAME)

# Install to Applications
install: sign
	@echo "Installing to /Applications..."
	@rm -rf /Applications/$(APP_BUNDLE)
	@cp -R $(APP_BUNDLE) /Applications/
	@echo "Installed to /Applications/$(APP_BUNDLE)"

# Xcode project generation
xcode:
	swift package generate-xcodeproj
	@echo "Xcode project generated: $(APP_NAME).xcodeproj"

# Format code
format:
	swift-format -i -r Sources/

# Stream debug logs (run in separate terminal)
logs:
	log stream --predicate 'subsystem == "com.voicey.app"' --level debug

# Help
help:
	@echo "Voicey Build System"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@echo "  build    - Build debug version (default)"
	@echo "  release  - Build release version"
	@echo "  bundle   - Create app bundle from release build"
	@echo "  sign     - Sign the app bundle"
	@echo "  clean    - Clean build artifacts"
	@echo "  run      - Build and run debug version"
	@echo "  logs     - Stream debug logs (run in separate terminal)"
	@echo "  install  - Install to /Applications"
	@echo "  xcode    - Generate Xcode project"
	@echo "  help     - Show this help"
