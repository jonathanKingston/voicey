# Voicey

A macOS menubar application that provides system-wide voice-to-text transcription using on-device Whisper models powered by WhisperKit.

## Features

- **Privacy-first**: All transcription runs on-device using CoreML; network access only for model downloads
- **Low friction**: Single hotkey to toggle (default: `Ctrl+V`), minimal UI, instant output
- **Intelligent output**: Punctuation inferred from speech timing and patterns, noise filtering removes artifacts
- **Smart model management**: Starts fast with a lightweight model, automatically upgrades to higher quality in the background
- **Performance monitoring**: Real-time factor tracking with suggestions when system is under load
- **Unobtrusive**: Small overlay, menubar-only presence, no dock icon

## Requirements

- macOS 13.0 (Ventura) or later
- Apple Silicon (M1+) required for WhisperKit CoreML acceleration
- Microphone access permission
- Network access (for downloading AI models on first launch)
- Optional: Accessibility permission (only if enabling auto-paste)

## Building

### Prerequisites

1. Xcode 15.0 or later
2. Swift 5.9 or later

### Build from Source

```bash
cd voicey

# Build debug version
make build

# Build release version and create app bundle
make bundle

# Sign and install to /Applications
make install
```

### Alternative: Manual Build

```bash
# Build with Swift Package Manager
swift build -c release

# The binary will be in .build/release/Voicey
```

### Open in Xcode

```bash
# Generate Xcode project
make xcode

# Open in Xcode
open Voicey.xcodeproj
```

## Usage

### First Launch

1. Launch Voicey from Applications or build output
2. Grant microphone permission when prompted
3. Download a transcription model (Large v3 Turbo recommended for best speed/accuracy balance)

### Recording

1. Press `Ctrl+V` (or your custom hotkey) to start recording
2. Speak naturally - the app will detect punctuation from your speech timing
3. Press the hotkey again to stop and transcribe
4. Press `ESC` to cancel without transcribing

### Settings

Access settings from the menubar icon:
- **General**: Output (clipboard), launch at login, dock icon visibility
- **Hotkey**: Customize the recording hotkey
- **Audio**: Select input device, test microphone
- **Model**: Download/manage Whisper models
- **Voice Commands**: Enable optional voice commands (new line, new paragraph, scratch that)

## Models

| Model | Disk Size | Memory | Notes |
|-------|-----------|--------|-------|
| Large v3 Turbo | ~1.5GB | ~3GB | **Recommended** - Fast & accurate, 8x faster than Large |
| Large v3 | ~3GB | ~6GB | Maximum accuracy, slower |
| Distil Large v3 | ~800MB | ~2GB | Distilled model, good balance |
| Small (English) | ~250MB | ~600MB | Fast, English-only |
| Base (English) | ~80MB | ~200MB | Very fast, basic accuracy |
| Tiny (English) | ~40MB | ~100MB | Fastest, lowest accuracy |

*Note: First load of each model requires CoreML compilation (1-3 minutes). Subsequent loads are instant.*

## Post-Processing

Voicey includes intelligent post-processing:

- **Noise filtering**: Removes Whisper artifacts like `[music]`, `*click*`, breathing sounds, etc.
- **Intelligent punctuation**: Adds periods, commas, and question marks based on speech timing and patterns
- **Text expansions**: Converts common phrases (e.g., "etcetera" → "etc.", "mister" → "Mr.")
- **Voice commands** (optional): "new line", "new paragraph", "scratch that"

## Architecture

```
Voicey/
├── App/                    # App entry, lifecycle, menubar
├── Audio/                  # Audio capture and level monitoring
├── Transcription/          # WhisperKit engine, model management, post-processing
├── Output/                 # Clipboard output
├── UI/                     # Overlay, settings, onboarding views
├── Input/                  # Hotkey management and keybinding recorder
└── Utilities/              # Permissions, settings, notifications, logging
```

## Dependencies

- [WhisperKit](https://github.com/argmaxinc/WhisperKit) - CoreML-optimized Whisper inference for Apple Silicon
- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) - Global hotkey management

## Permissions

| Permission | Purpose |
|------------|---------|
| Microphone | Audio capture for transcription |
| Network | Model downloads from Hugging Face |

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- OpenAI for the Whisper model
- Argmax for WhisperKit
- Sindre Sorhus for KeyboardShortcuts
