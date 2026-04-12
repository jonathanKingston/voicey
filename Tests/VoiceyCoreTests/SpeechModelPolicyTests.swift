import XCTest
@testable import VoiceyCore

final class SpeechModelPolicyTests: XCTestCase {
  private let gibibyteBytes: UInt64 = 1_073_741_824

  func testRecommendedModelUsesSmallQwenBelowThreshold() {
    let memory = 8 * gibibyteBytes
    let recommended = SpeechModelCatalog.recommendedModel(availableMemoryBytes: memory)
    XCTAssertEqual(recommended, .qwen3Small)
  }

  func testRecommendedModelUsesLargeQwenAtThreshold() {
    let memory = 16 * gibibyteBytes
    let recommended = SpeechModelCatalog.recommendedModel(availableMemoryBytes: memory)
    XCTAssertEqual(recommended, .qwen3Large)
  }

  func testSupportedModelsFiltersByMemoryRequirement() {
    let lowMemoryModels = SpeechModelCatalog.supportedModels(availableMemoryBytes: 8 * gibibyteBytes)
    XCTAssertTrue(lowMemoryModels.contains(.qwen3Small))
    XCTAssertFalse(lowMemoryModels.contains(.qwen3Large))
  }

  func testIsModelSupportedUsesRawIdentifier() {
    let lowMemory = 8 * gibibyteBytes
    XCTAssertTrue(
      SpeechModelCatalog.isModelSupported(
        SpeechModel.qwen3Small.rawValue,
        availableMemoryBytes: lowMemory
      )
    )
    XCTAssertFalse(
      SpeechModelCatalog.isModelSupported(
        SpeechModel.qwen3Large.rawValue,
        availableMemoryBytes: lowMemory
      )
    )
  }
}
