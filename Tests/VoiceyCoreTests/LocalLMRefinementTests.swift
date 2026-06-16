import XCTest
@testable import VoiceyCore

final class LocalLMRefinementTests: XCTestCase {
  func testNormalizedChatCompletionsURLAcceptsLMStudioDefault() throws {
    let url = try LocalLMRefinementURL.normalizedChatCompletionsURL(
      baseURL: "http://127.0.0.1:1234/v1"
    )
    XCTAssertEqual(url.absoluteString, "http://127.0.0.1:1234/v1/chat/completions")
  }

  func testNormalizedChatCompletionsURLAcceptsOllamaDefault() throws {
    let url = try LocalLMRefinementURL.normalizedChatCompletionsURL(
      baseURL: "http://localhost:11434/v1/"
    )
    XCTAssertEqual(url.absoluteString, "http://localhost:11434/v1/chat/completions")
  }

  func testNormalizedChatCompletionsURLAddsV1SegmentWhenMissing() throws {
    let url = try LocalLMRefinementURL.normalizedChatCompletionsURL(
      baseURL: "http://127.0.0.1:1234"
    )
    XCTAssertEqual(url.absoluteString, "http://127.0.0.1:1234/v1/chat/completions")
  }

  func testNormalizedChatCompletionsURLRejectsRemoteHosts() {
    XCTAssertThrowsError(
      try LocalLMRefinementURL.normalizedChatCompletionsURL(baseURL: "http://example.com/v1")
    ) { error in
      XCTAssertEqual(error as? LocalLMRefinementError, .invalidBaseURL)
    }
  }

  func testUserMessagePrefersDecoderContext() {
    let message = LocalLMRefinementPrompt.userMessage(
      transcript: "open composer",
      steeringTerms: ["Composer"],
      decoderContext: "Vocabulary: Voicey, Composer"
    )
    XCTAssertTrue(message.hasPrefix("Vocabulary: Voicey, Composer"))
    XCTAssertTrue(message.hasSuffix("Transcript:\nopen composer"))
  }

  func testUserMessageFallsBackToSteeringTerms() {
    let message = LocalLMRefinementPrompt.userMessage(
      transcript: "open composer",
      steeringTerms: ["Voicey", "Composer"],
      decoderContext: nil
    )
    XCTAssertTrue(message.contains("Vocabulary: Voicey, Composer"))
  }
}
