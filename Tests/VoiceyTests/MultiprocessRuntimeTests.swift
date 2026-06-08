import XCTest

@testable import Voicey

final class MultiprocessRuntimeTests: XCTestCase {
  func testQwenUsesInferWorkerByDefault() {
    let prior = ProcessInfo.processInfo.environment["VOICEY_RUNTIME"]
    defer {
      if let prior {
        setenv("VOICEY_RUNTIME", prior, 1)
      } else {
        unsetenv("VOICEY_RUNTIME")
      }
    }
    unsetenv("VOICEY_RUNTIME")
    XCTAssertTrue(VoiceyRuntimeConfiguration.usesInferWorker(for: .qwen3Small))
    XCTAssertFalse(VoiceyRuntimeConfiguration.usesInferWorker(for: .largeTurbo))
  }

  func testInProcessOverrideDisablesInferWorker() {
    setenv("VOICEY_RUNTIME", "in-process", 1)
    XCTAssertFalse(VoiceyRuntimeConfiguration.usesInferWorker(for: .qwen3Small))
  }

  func testSharedMemoryPCMReadSlice() throws {
    let samples: [Float] = [0, 0.25, -0.5, 1.0, 0.75]
    let name = try SharedMemoryPCM.write(samples: samples)
    defer { SharedMemoryPCM.remove(name: name) }
    let slice = try SharedMemoryPCM.read(name: name, sampleCount: 3, sampleOffset: 1)
    XCTAssertEqual(slice, [0.25, -0.5, 1.0])
  }

  func testSharedMemoryPCMRoundTrip() throws {
    let samples: [Float] = [0.0, 0.25, -0.5, 1.0]
    let name = try SharedMemoryPCM.write(samples: samples)
    defer { SharedMemoryPCM.remove(name: name) }
    let read = try SharedMemoryPCM.read(name: name, sampleCount: samples.count)
    XCTAssertEqual(read, samples)
  }

  func testSharedMemoryPCMWriteSetsOwnerOnlyPermissions() throws {
    let name = try SharedMemoryPCM.write(samples: [1.0])
    defer { SharedMemoryPCM.remove(name: name) }
    let url = SharedMemoryPCM.fileURL(for: name)
    let permissions =
      try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
    XCTAssertEqual(permissions?.uint16Value, 0o600)
  }

  func testCleanupStaleFilesRemovesMatchingButPreservesUnrelatedFiles() throws {
    // A real voicey_pcm_* file (32-hex id + .pcm) should be swept...
    let staleName = try SharedMemoryPCM.write(samples: [1.0])
    let staleURL = SharedMemoryPCM.fileURL(for: staleName)
    // ...but a temp file that does not match the naming contract must survive.
    let unrelatedURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("voicey_pcm_not_a_uuid.pcm")
    try Data([0]).write(to: unrelatedURL)
    defer { try? FileManager.default.removeItem(at: unrelatedURL) }

    SharedMemoryPCM.cleanupStaleFiles()

    XCTAssertFalse(
      FileManager.default.fileExists(atPath: staleURL.path),
      "stale voicey_pcm_* file should be removed")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: unrelatedURL.path),
      "non-matching temp file must not be swept")
  }

  func testCapturedAudioSharedBufferDuration() {
    let handle = PCMBufferHandle(
      shmName: "voicey_pcm_test", sampleCount: 16_000, sampleRate: 16_000)
    let captured = CapturedAudio.sharedBuffer(handle)
    XCTAssertEqual(captured.sampleCount, 16_000)
    XCTAssertEqual(captured.durationSeconds, 1.0, accuracy: 0.001)
  }

  func testCapturedAudioInMemoryDuration() {
    let captured = CapturedAudio.inMemory(Array(repeating: 0, count: 8_000))
    XCTAssertEqual(captured.sampleCount, 8_000)
    XCTAssertEqual(captured.durationSeconds, 0.5, accuracy: 0.001)
    captured.removeSharedBufferIfNeeded()
  }

  /// Hands-free Rust capture now transfers PCM-file ownership to the consumer via a
  /// `.sharedBuffer` handle instead of reading `[Float]` in the drain call (#70 Phase 1).
  /// The whole no-leak contract rests on `removeSharedBufferIfNeeded()` actually unlinking
  /// that file once a consumer is done with it.
  func testRemoveSharedBufferIfNeededUnlinksBackingFile() throws {
    let name = try SharedMemoryPCM.write(samples: [0.0, 0.25, -0.5, 1.0])
    let path = SharedMemoryPCM.fileURL(for: name).path
    XCTAssertTrue(FileManager.default.fileExists(atPath: path))

    let captured = CapturedAudio.sharedBuffer(
      PCMBufferHandle(shmName: name, sampleCount: 4, sampleRate: 16_000))
    captured.removeSharedBufferIfNeeded()
    XCTAssertFalse(FileManager.default.fileExists(atPath: path))

    // Idempotent: a second removal (e.g. a defensive double-free) must not throw.
    captured.removeSharedBufferIfNeeded()
  }

  func testPCMBufferHandleDurationGuardsZeroSampleRate() {
    let handle = PCMBufferHandle(shmName: "voicey_pcm_test", sampleCount: 16_000, sampleRate: 0)
    XCTAssertEqual(handle.durationSeconds, 0)
    XCTAssertEqual(CapturedAudio.sharedBuffer(handle).durationSeconds, 0)
  }
}
