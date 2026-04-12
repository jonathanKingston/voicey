import XCTest
@testable import VoiceyCore

final class SpeechModelPolicyTests: XCTestCase {
  private let gibibyteBytes: UInt64 = 1_073_741_824

  func testRecommendedModelUsesSmallQwenBelowThreshold() {
    let memory = 8 * gibibyteBytes
    let recommended = SpeechModelCatalog.recommendedModel(availableMemoryBytes: memory)
    XCTAssertEqual(recommended.identifier, SpeechModelCatalog.qwen3Small.identifier)
  }

  func testRecommendedModelUsesLargeQwenAtThreshold() {
    let memory = 16 * gibibyteBytes
    let recommended = SpeechModelCatalog.recommendedModel(availableMemoryBytes: memory)
    XCTAssertEqual(recommended.identifier, SpeechModelCatalog.qwen3Large.identifier)
  }

  func testSupportedModelsFiltersByMemoryRequirement() {
    let lowMemoryModels = SpeechModelCatalog.supportedModels(availableMemoryBytes: 8 * gibibyteBytes)
    XCTAssertTrue(lowMemoryModels.contains(where: { $0.identifier == SpeechModelCatalog.qwen3Small.identifier }))
    XCTAssertFalse(lowMemoryModels.contains(where: { $0.identifier == SpeechModelCatalog.qwen3Large.identifier }))
  }
}
