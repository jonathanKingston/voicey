import Foundation

public enum SpeechBackendKind: String, CaseIterable, Sendable {
  case whisperKit
  case granitePython
  case qwenMLX
}
