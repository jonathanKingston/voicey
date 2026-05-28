import Foundation

/// Inference backends referenced by `SpeechModel`.
///
/// The production app uses `.qwenMLX` only. `.whisperKit` and `.granitePython` remain for
/// benchmark and runtime-parity CLI commands (`benchmark-transcribe`, Common Voice harness, etc.).
enum SpeechBackendKind: String, CaseIterable, Sendable {
  case whisperKit
  case granitePython
  case qwenMLX
}
