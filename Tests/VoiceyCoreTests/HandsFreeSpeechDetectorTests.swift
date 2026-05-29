import XCTest

@testable import VoiceyCore

final class HandsFreeSpeechDetectorTests: XCTestCase {
  func testSpeechStartIncludesConfiguredPreRoll() {
    var detector = HandsFreeSpeechDetector(
      configuration: HandsFreeRecordingConfiguration(
        sampleRate: 16_000,
        preRollDuration: 0.1,
        speechStartThreshold: 0.09,
        speechEndThreshold: 0.045,
        minimumSpeechDuration: 0.18,
        silenceHangoverDuration: 0.8,
        waitTimeoutDuration: 8.0
      )
    )

    XCTAssertTrue(detector.consume(level: 0.02, totalSamplesCaptured: 3_200).isEmpty)

    let events = detector.consume(level: 0.12, totalSamplesCaptured: 7_000)
    XCTAssertEqual(events, [.speechStarted(startSampleIndex: 1_600)])
    XCTAssertEqual(detector.phase, .recording)
  }

  func testSpeechEndsAfterConfiguredSilenceHangover() {
    var detector = HandsFreeSpeechDetector(
      configuration: HandsFreeRecordingConfiguration(
        sampleRate: 16_000,
        preRollDuration: 0.25,
        speechStartThreshold: 0.09,
        speechEndThreshold: 0.045,
        minimumSpeechDuration: 0.18,
        silenceHangoverDuration: 0.8,
        waitTimeoutDuration: 8.0
      )
    )

    _ = detector.consume(level: 0.12, totalSamplesCaptured: 5_000)
    XCTAssertEqual(detector.phase, .recording)

    XCTAssertTrue(detector.consume(level: 0.12, totalSamplesCaptured: 8_000).isEmpty)
    let events = detector.consume(level: 0.02, totalSamplesCaptured: 21_000)

    XCTAssertEqual(events, [.speechEnded(endSampleIndex: 8_000)])
    XCTAssertEqual(detector.phase, .speechEnded)
  }

  func testBoundedSamplesReturnsOnlyDetectedSpeechWindow() {
    var detector = HandsFreeSpeechDetector(
      configuration: HandsFreeRecordingConfiguration(
        sampleRate: 10,
        preRollDuration: 0.2,
        speechStartThreshold: 0.09,
        speechEndThreshold: 0.045,
        minimumSpeechDuration: 0.2,
        silenceHangoverDuration: 0.3,
        waitTimeoutDuration: 8.0
      )
    )

    _ = detector.consume(level: 0.5, totalSamplesCaptured: 4)
    _ = detector.consume(level: 0.5, totalSamplesCaptured: 7)
    _ = detector.consume(level: 0.0, totalSamplesCaptured: 10)

    let samples = Array(0..<12).map(Float.init)
    XCTAssertEqual(detector.boundedSamples(from: samples), [0, 1, 2, 3, 4, 5, 6])
  }

  func testBoundedSamplesIsEmptyWhenSpeechNeverStarts() {
    var detector = HandsFreeSpeechDetector()
    XCTAssertTrue(detector.consume(level: 0.01, totalSamplesCaptured: 2_000).isEmpty)
    XCTAssertEqual(detector.boundedSamples(from: Array(repeating: 0.0, count: 2_000)), [])
  }
}
