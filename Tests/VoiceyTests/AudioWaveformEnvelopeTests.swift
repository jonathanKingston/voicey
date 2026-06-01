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

  func testNormalizedBarsFromSharedBufferMatchesInMemoryEnvelope() throws {
    var samples = [Float](repeating: 0.01, count: 4_800)
    for index in 2_000..<3_000 {
      samples[index] = 0.85
    }
    let name = try SharedMemoryPCM.write(samples: samples)
    defer { SharedMemoryPCM.remove(name: name) }

    let handle = PCMBufferHandle(shmName: name, sampleCount: samples.count, sampleRate: 16_000)
    let fromFile = try AudioWaveformEnvelope.normalizedBars(fromSharedBuffer: handle, barCount: 8)
    let fromMemory = AudioWaveformEnvelope.normalizedBars(from: samples, barCount: 8)

    XCTAssertEqual(fromFile.count, 8)
    XCTAssertEqual(fromFile, fromMemory)
  }

  func testCapturedAudioWaveformEnvelopeUsesSharedPCM() throws {
    let samples: [Float] = [0.1, 0.5, 0.9, 0.2]
    let name = try SharedMemoryPCM.write(samples: samples)
    defer { SharedMemoryPCM.remove(name: name) }

    let captured = CapturedAudio.sharedBuffer(
      PCMBufferHandle(shmName: name, sampleCount: samples.count, sampleRate: 16_000))
    let envelope = captured.waveformEnvelope()
    XCTAssertEqual(envelope.count, AudioWaveformEnvelope.displayBarCount)
    XCTAssertGreaterThan(envelope.max() ?? 0, envelope.min() ?? 0)
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
