# Changelog

All notable changes to Voicey direct distribution releases are documented here.

## [1.6.0] - 2026-05-27

### Highlights

- **Rust multiprocess runtime** ships in release bundles: `voicey-capture`, `voicey-fetch`, and `voicey-supervisor` are built in release mode, bundled under `Voicey.app/Contents/MacOS/`, and codesigned for notarization.
- **Qwen-only** user-facing models with on-device MLX inference via the infer worker.
- **Screen context & glossary** steering for Qwen (Accessibility harvest, optional OCR fallback, custom vocabulary).
- **Liquid-glass** transcription overlay with waveform progress during decode.
- **Long dictation** improvements: token budget, chunking, and aligned capture limits (~10 minutes per take).

### Added

- Rust workers on the default hot path (capture, fetch, supervisor) when binaries are present in the bundle.
- Qwen transcription glossary and BM25 screen-term context before decode.
- Waveform envelope UI during Qwen transcription.
- Linux Rust CI for the workspace.
- macOS dev restart skill and `scripts/voicey_restart.sh`.

### Fixed

- Intermittent auto-paste inserting stale clipboard content.
- Settings hotkey recorder crash.
- Custom vocabulary editor placeholder alignment.
- Overlay waveform color and glass halo styling.

### Changed

- Media pause uses JXA/Now Playing only (Perl MediaRemote adapter removed).
- Release `bundle-direct` includes release-profile Rust workers (see PR #52).

## [1.5.0] - 2026-05-08

See [GitHub release v1.5.0](https://github.com/jonathanKingston/voicey/releases/tag/v1.5.0).
