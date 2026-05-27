import Foundation

/// Hotkey recording duration guard (keep in sync with `MAX_RECORDING_SECONDS` in `voicey-capture`).
enum RecordingDurationLimits {
  /// ~10 minutes at 16 kHz mono (~19 MB). Qwen decode is capped separately via `maxTokens`.
  static let maxSeconds: TimeInterval = 600
}
