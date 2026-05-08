import XCTest

@testable import VoiceyCore

final class AudioChunkerTests: XCTestCase {
  func testChunksAudioAtMaximumDurationBoundary() {
    let sampleRate = 4.0
    let samples = Array(repeating: Float(1), count: 10)

    let chunks = AudioChunker.chunks(from: samples, maxDuration: 1, sampleRate: sampleRate)

    XCTAssertEqual(chunks.map(\.samples.count), [4, 4, 2])
    XCTAssertEqual(chunks.map(\.startSample), [0, 4, 8])
    XCTAssertEqual(chunks.map(\.duration), [1.0, 1.0, 0.5])
  }

  func testReturnsNoChunksForEmptyAudio() {
    let chunks = AudioChunker.chunks(from: [], maxDuration: 30, sampleRate: 16_000)

    XCTAssertTrue(chunks.isEmpty)
  }
}
