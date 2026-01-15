# Voicey

A macOS menubar application that provides system-wide voice-to-text transcription using on-device Whisper models.

## Features

- **Privacy-first**: All transcription runs on-device; network access only for model downloads
- **Low friction**: Single hotkey to toggle (default: `Ctrl+V`), minimal UI, instant output
- **Expressive output**: Punctuation inferred from speech patterns, not voice commands
- **Unobtrusive**: Small overlay, menubar-only presence, no dock icon

## Requirements

- macOS 13.0 (Ventura) or later
- Apple Silicon (M1+) recommended for optimal performance
- Microphone access permission
- Accessibility permission (for global hotkey and paste functionality)

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
3. Grant accessibility permission in System Settings > Privacy & Security > Accessibility
4. Download a transcription model (Base model recommended for balance of speed/accuracy)

### Recording

1. Press `Ctrl+V` (or your custom hotkey) to start recording
2. Speak naturally - the app will detect punctuation from your intonation
3. Press the hotkey again to stop and transcribe
4. Press `ESC` to cancel without transcribing

### Settings

Access settings from the menubar icon:
- **General**: Output mode, launch at login, dock icon visibility
- **Hotkey**: Customize the recording hotkey
- **Audio**: Select input device, test microphone
- **Model**: Download/manage Whisper models, GPU acceleration
- **Voice Commands**: Enable optional voice commands (new line, new paragraph, etc.)

## Models

| Model | Size | Memory | Speed | Accuracy |
|-------|------|--------|-------|----------|
| Tiny | ~75MB | ~125MB | ~10x | Good |
| Base | ~150MB | ~250MB | ~7x | Better |
| Small | ~500MB | ~850MB | ~4x | Very Good |
| Medium | ~1.5GB | ~2.5GB | ~2x | Excellent |

*Speed relative to realtime on M1 MacBook Air*

## Architecture

```
Voicey/
├── App/                    # App entry, lifecycle, menubar
├── Audio/                  # Audio capture and processing
├── Transcription/          # Whisper engine and post-processing
├── Output/                 # Clipboard and paste simulation
├── UI/                     # Overlay and settings windows
├── Input/                  # Hotkey management
└── Utilities/              # Permissions, settings, notifications
```

## Dependencies

- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) - Whisper inference engine
- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) - Global hotkey management

## Permissions

| Permission | Purpose |
|------------|---------|
| Microphone | Audio capture for transcription |
| Accessibility | Global hotkey registration, paste simulation |
| Network | Model downloads from Hugging Face |

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- OpenAI for the Whisper model
- ggerganov for whisper.cpp
- Sindre Sorhus for KeyboardShortcuts
