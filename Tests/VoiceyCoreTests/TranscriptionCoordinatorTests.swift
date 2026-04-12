import XCTest
@testable import VoiceyCore

final class TranscriptionCoordinatorTests: XCTestCase {
  func testStopRecordingTransitionsToCompletedAndDeliversText() async throws {
    let audio = MockAudioCapturer(samplesToReturn: [0.1, 0.2, 0.3])
    let speech = MockSpeechEngine(
      result: TranscriptionResult(
        text: "hello world",
        segments: [],
        language: "en",
        processingTime: 0.15,
        performanceMetrics: PerformanceMetrics(
          realTimeFactor: 0.5,
          audioDuration: 0.3,
          processingTime: 0.15,
          thermalState: .nominal
        )
      )
    )
    let deliverer = MockTextDeliverer()
    let coordinator = TranscriptionCoordinator(
      audioCapturer: audio,
      speechEngine: speech,
      textDeliverer: deliverer,
      dateProvider: { Date(timeIntervalSince1970: 100) }
    )

    try await coordinator.startRecording(requestID: "request-1")
    try await coordinator.stopRecording()

    guard case .completed(let text, let metadata) = await coordinator.state else {
      XCTFail("Expected completed state")
      return
    }

    XCTAssertEqual(text, "hello world")
    XCTAssertEqual(metadata.language, "en")
    XCTAssertEqual(metadata.modelIdentifier, "unknown")
    XCTAssertEqual(deliverer.deliveredTexts, ["hello world"])
  }

  func testStopRecordingWithoutRequestContextFailsFast() async throws {
    let coordinator = TranscriptionCoordinator(
      audioCapturer: MockAudioCapturer(),
      speechEngine: MockSpeechEngine(result: .stub(text: "unused")),
      textDeliverer: MockTextDeliverer()
    )

    do {
      try await coordinator.stopRecording()
      XCTFail("Expected stopRecording to throw")
    } catch let error as TranscriptionCoordinatorError {
      XCTAssertEqual(error, .missingRequestContext)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testStopRecordingWithEmptyTextTransitionsToFailed() async throws {
    let audio = MockAudioCapturer(samplesToReturn: [0.1])
    let speech = MockSpeechEngine(result: .stub(text: "   "))
    let coordinator = TranscriptionCoordinator(
      audioCapturer: audio,
      speechEngine: speech,
      textDeliverer: MockTextDeliverer()
    )

    try await coordinator.startRecording(requestID: "request-2")

    do {
      try await coordinator.stopRecording()
      XCTFail("Expected stopRecording to throw for empty text")
    } catch let error as TranscriptionCoordinatorError {
      XCTAssertEqual(error, .emptyTranscription)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    guard case .failed(let message) = await coordinator.state else {
      XCTFail("Expected failed state")
      return
    }
    XCTAssertTrue(message.contains("empty"))
  }

  func testCancelResetsStateToIdle() async throws {
    let coordinator = TranscriptionCoordinator(
      audioCapturer: MockAudioCapturer(samplesToReturn: [0.1]),
      speechEngine: MockSpeechEngine(result: .stub(text: "hello")),
      textDeliverer: MockTextDeliverer()
    )

    try await coordinator.startRecording(requestID: "request-3")
    await coordinator.cancel()

    let state = await coordinator.state
    XCTAssertEqual(state, .idle)
  }
}

private extension TranscriptionResult {
  static func stub(text: String) -> TranscriptionResult {
    TranscriptionResult(
      text: text,
      segments: [],
      language: "auto",
      processingTime: 0,
      performanceMetrics: PerformanceMetrics(
        realTimeFactor: 0,
        audioDuration: 0,
        processingTime: 0,
        thermalState: .nominal
      )
    )
  }
}

private final class MockAudioCapturer: @unchecked Sendable, AudioCapturing {
  private let samplesToReturn: [Float]

  init(samplesToReturn: [Float] = []) {
    self.samplesToReturn = samplesToReturn
  }

  func start() throws {}

  func stop() throws -> [Float] {
    samplesToReturn
  }
}

private final class MockSpeechEngine: @unchecked Sendable, SpeechEngine {
  let result: TranscriptionResult

  init(result: TranscriptionResult) {
    self.result = result
  }

  var isReady: Bool { true }

  func preload(modelIdentifier: String) async throws {}

  func transcribe(samples: [Float]) async throws -> TranscriptionResult {
    result
  }
}

private final class MockTextDeliverer: @unchecked Sendable, TextDelivering {
  private(set) var deliveredTexts: [String] = []

  func deliver(text: String) async throws {
    deliveredTexts.append(text)
  }
}
