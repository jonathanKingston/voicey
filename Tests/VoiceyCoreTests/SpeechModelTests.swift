import XCTest
@testable import VoiceyCore

final class SpeechModelTests: XCTestCase {
  func testBackendMappingsMatchModelFamilies() {
    XCTAssertEqual(SpeechModel.graniteSpeech.backendKind, .granitePython)
    XCTAssertEqual(SpeechModel.qwen3Small.backendKind, .qwenMLX)
    XCTAssertEqual(SpeechModel.largeTurbo.backendKind, .whisperKit)
  }

  func testModelCapabilityFlagsAreConsistent() {
    XCTAssertTrue(SpeechModel.graniteSpeech.isGraniteModel)
    XCTAssertFalse(SpeechModel.graniteSpeech.isWhisperModel)
    XCTAssertTrue(SpeechModel.qwen3Large.isQwenModel)
    XCTAssertTrue(SpeechModel.baseEn.isEnglishOnly)
    XCTAssertFalse(SpeechModel.base.isEnglishOnly)
  }

  func testWhisperRepositoryIdentifierExistsOnlyForWhisperModels() {
    XCTAssertNil(SpeechModel.graniteSpeech.whisperKitModelId)
    XCTAssertNil(SpeechModel.qwen3Small.whisperKitModelId)
    XCTAssertEqual(SpeechModel.largeTurbo.whisperKitModelId, "openai_whisper-large-v3_turbo")
  }
}
