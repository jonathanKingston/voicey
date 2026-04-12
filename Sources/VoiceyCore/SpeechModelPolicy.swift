import Foundation

public enum CoreSpeechBackend: String, CaseIterable, Sendable {
  case whisperKit
  case qwenMLX
}

public struct CoreSpeechModel: Equatable, Sendable {
  public let identifier: String
  public let backend: CoreSpeechBackend
  public let minimumMemoryBytes: UInt64
  public let preferredForIOSKeyboard: Bool

  public init(
    identifier: String,
    backend: CoreSpeechBackend,
    minimumMemoryBytes: UInt64 = 0,
    preferredForIOSKeyboard: Bool
  ) {
    self.identifier = identifier
    self.backend = backend
    self.minimumMemoryBytes = minimumMemoryBytes
    self.preferredForIOSKeyboard = preferredForIOSKeyboard
  }
}

public enum SpeechModelCatalog {
  private static let gibibyteBytes: UInt64 = 1_073_741_824
  private static let largeQwenMemoryThresholdBytes: UInt64 = 16 * gibibyteBytes

  public static let qwen3Small = CoreSpeechModel(
    identifier: "qwen3-asr-0.6b-6bit",
    backend: .qwenMLX,
    minimumMemoryBytes: 0,
    preferredForIOSKeyboard: true
  )

  public static let qwen3Large = CoreSpeechModel(
    identifier: "qwen3-asr-1.7b-bf16",
    backend: .qwenMLX,
    minimumMemoryBytes: largeQwenMemoryThresholdBytes,
    preferredForIOSKeyboard: false
  )

  public static let whisperBase = CoreSpeechModel(
    identifier: "base",
    backend: .whisperKit,
    minimumMemoryBytes: 0,
    preferredForIOSKeyboard: false
  )

  public static let all: [CoreSpeechModel] = [qwen3Small, qwen3Large, whisperBase]

  public static func recommendedModel(availableMemoryBytes: UInt64) -> CoreSpeechModel {
    if availableMemoryBytes >= largeQwenMemoryThresholdBytes {
      return qwen3Large
    }
    return qwen3Small
  }

  public static func supportedModels(availableMemoryBytes: UInt64) -> [CoreSpeechModel] {
    all.filter { availableMemoryBytes >= $0.minimumMemoryBytes }
  }

  public static func isModelSupported(_ identifier: String, availableMemoryBytes: UInt64) -> Bool {
    supportedModels(availableMemoryBytes: availableMemoryBytes)
      .contains(where: { $0.identifier == identifier })
  }
}
