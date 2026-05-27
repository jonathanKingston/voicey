import XCTest
@testable import Voicey

final class AudioWaveformEnvelopeTests: XCTestCase {
  func testNormalizedBarsReturnsFixedCountForEmptyInput() {
    let bars = AudioWaveformEnvelope.normalizedBars(from: [])
    XCTAssertEqual(bars.count, AudioWaveformEnvelope.displayBarCount)
  }

  func testNormalizedBarsReflectsLouderSegment() {
    var samples = [Float](repeating: 0.01, count: 16_000)
    for index in 8_000..<12_000 {
      samples[index] = 0.9
    }

    let bars = AudioWaveformEnvelope.normalizedBars(from: samples, barCount: 8)
    XCTAssertEqual(bars.count, 8)

    let peak = bars.max() ?? 0
    let quiet = bars.prefix(2).max() ?? 0
    XCTAssertGreaterThan(peak, quiet)
    XCTAssertEqual(peak, 1.0, accuracy: 0.001)
  }

  func testEstimatedProcessingProgressCapsBeforeCompletion() {
    let start = Date(timeIntervalSinceReferenceDate: 0)
    let now = Date(timeIntervalSinceReferenceDate: 5)
    let progress = AudioWaveformEnvelope.estimatedProcessingProgress(
      startedAt: start,
      now: now,
      audioDuration: 10,
      estimatedRTF: 1.0
    )
    XCTAssertEqual(progress, 0.5, accuracy: 0.001)
    XCTAssertLessThanOrEqual(progress, 0.92)
  }
}
