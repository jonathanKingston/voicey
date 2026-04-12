import Foundation

public enum SpeechModelCatalog {
  private static let gibibyteBytes: UInt64 = 1_073_741_824
  private static let largeQwenMemoryThresholdBytes: UInt64 = 16 * gibibyteBytes

  public static let qwen3Small = SpeechModel.qwen3Small
  public static let qwen3Large = SpeechModel.qwen3Large
  public static let whisperBase = SpeechModel.base

  public static let all: [SpeechModel] = [qwen3Small, qwen3Large, whisperBase]

  public static func recommendedModel(availableMemoryBytes: UInt64) -> SpeechModel {
    if availableMemoryBytes >= largeQwenMemoryThresholdBytes {
      return qwen3Large
    }
    return qwen3Small
  }

  public static func supportedModels(availableMemoryBytes: UInt64) -> [SpeechModel] {
    all.filter { model in
      if model == .qwen3Large {
        return availableMemoryBytes >= largeQwenMemoryThresholdBytes
      }
      return true
    }
  }

  public static func isModelSupported(_ identifier: String, availableMemoryBytes: UInt64) -> Bool {
    supportedModels(availableMemoryBytes: availableMemoryBytes)
      .contains(where: { $0.rawValue == identifier })
  }
}
