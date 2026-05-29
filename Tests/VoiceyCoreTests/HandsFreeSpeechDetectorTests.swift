import XCTest

@testable import VoiceyCore

final class HandsFreeSpeechDetectorTests: XCTestCase {
  func testSpeechStartIncludesOnsetBeforeHardThresholdDuringCalibration() {
    var detector = HandsFreeSpeechDetector(
      configuration: HandsFreeRecordingConfiguration(
        sampleRate: 16_000,
        preRollDuration: 0.25,
        speechStartThreshold: 0.09,
        speechEndThreshold: 0.045,
        minimumSpeechDuration: 0.18,
        silenceHangoverDuration: 0.8,
        waitTimeoutDuration: 8.0,
        minimumCalibrationDuration: 0.35
      )
    )

    _ = detector.consume(level: 0.02, totalSamplesCaptured: 800)
    _ = detector.consume(level: 0.11, totalSamplesCaptured: 4_800)
    let events = detector.consume(level: 0.35, totalSamplesCaptured: 8_000)

    XCTAssertEqual(events.count, 1)
    guard case let .speechStarted(startSampleIndex) = events[0] else {
      return XCTFail("Expected speechStarted")
    }
    XCTAssertLessThan(startSampleIndex, 4_800 - 1_600)
    XCTAssertEqual(detector.phase, .recording)
  }

  func testSpeechStartIncludesConfiguredPreRoll() {
    var detector = HandsFreeSpeechDetector(
      configuration: HandsFreeRecordingConfiguration(
        sampleRate: 16_000,
        preRollDuration: 0.1,
        speechStartThreshold: 0.09,
        speechEndThreshold: 0.045,
        minimumSpeechDuration: 0.18,
        silenceHangoverDuration: 0.8,
        waitTimeoutDuration: 8.0,
        minimumCalibrationDuration: 0
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
        waitTimeoutDuration: 8.0,
        minimumCalibrationDuration: 0
      )
    )

    _ = detector.consume(level: 0.02, totalSamplesCaptured: 2_000)
    _ = detector.consume(level: 0.35, totalSamplesCaptured: 5_000)
    XCTAssertEqual(detector.phase, .recording)

    XCTAssertTrue(detector.consume(level: 0.35, totalSamplesCaptured: 8_000).isEmpty)
    let events = detector.consume(level: 0.02, totalSamplesCaptured: 21_000)

    XCTAssertEqual(events, [.speechEnded(endSampleIndex: 8_000)])
    XCTAssertEqual(detector.phase, .speechEnded)
  }

  func testHighAmbientNoiseDoesNotTriggerSpeechStart() {
    var detector = HandsFreeSpeechDetector(
      configuration: HandsFreeRecordingConfiguration(
        sampleRate: 16_000,
        minimumSpeechDuration: 0.18,
        silenceHangoverDuration: 0.8,
        waitTimeoutDuration: 8.0
      )
    )

    for sampleCount in stride(from: 1_600, through: 16_000, by: 1_600) {
      XCTAssertTrue(
        detector.consume(level: 0.14, totalSamplesCaptured: sampleCount).isEmpty,
        "Expected quiet ambient noise to stay in waiting phase at \(sampleCount) samples"
      )
    }
    XCTAssertEqual(detector.phase, .waitingForSpeech)
  }

  func testRecordingEndsWhenAmbientWasMistakenForSpeech() {
    var detector = HandsFreeSpeechDetector(
      configuration: HandsFreeRecordingConfiguration(
        sampleRate: 16_000,
        minimumSpeechDuration: 0.18,
        silenceHangoverDuration: 0.8,
        waitTimeoutDuration: 8.0,
        speechStartMarginAboveNoise: 0.05
      )
    )

    for sampleCount in stride(from: 1_600, through: 9_600, by: 1_600) {
      _ = detector.consume(level: 0.12, totalSamplesCaptured: sampleCount)
    }
    let startEvents = detector.consume(level: 0.22, totalSamplesCaptured: 12_800)
    XCTAssertEqual(startEvents, [.speechStarted(startSampleIndex: 5_600)])

    for sampleCount in stride(from: 14_400, through: 19_200, by: 1_600) {
      _ = detector.consume(level: 0.08, totalSamplesCaptured: sampleCount)
    }

    let endEvents = detector.consume(level: 0.08, totalSamplesCaptured: 28_800)
    XCTAssertEqual(endEvents, [.speechEnded(endSampleIndex: 12_800)])
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
        waitTimeoutDuration: 8.0,
        minimumCalibrationDuration: 0
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

  func testSpeechEndedPhaseRecoversForNextUtterance() {
    var detector = HandsFreeSpeechDetector(
      configuration: HandsFreeRecordingConfiguration(
        sampleRate: 16_000,
        minimumSpeechDuration: 0.18,
        silenceHangoverDuration: 0.8,
        waitTimeoutDuration: 8.0,
        minimumCalibrationDuration: 0
      )
    )

    _ = detector.consume(level: 0.02, totalSamplesCaptured: 2_000)
    _ = detector.consume(level: 0.35, totalSamplesCaptured: 5_000)
    _ = detector.consume(level: 0.35, totalSamplesCaptured: 8_000)
    _ = detector.consume(level: 0.02, totalSamplesCaptured: 21_000)
    XCTAssertEqual(detector.phase, .speechEnded)

    let nextStart = detector.consume(level: 0.35, totalSamplesCaptured: 25_000)
    XCTAssertFalse(nextStart.isEmpty)
    XCTAssertEqual(detector.phase, .recording)
  }

  func testBoundedSliceMatchesBoundedSamplesWindow() {
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

    let slice = detector.boundedSlice(in: 12)
    XCTAssertEqual(slice?.offset, 0)
    XCTAssertEqual(slice?.count, 7)
  }
}
