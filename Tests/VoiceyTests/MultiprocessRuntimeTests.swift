@testable import Voicey
import XCTest

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

  func testPostProcessorSegmentLessOutputStable() {
    let result = TranscriptionResult(
      text: "hello world",
      segments: [],
      language: "auto",
      processingTime: 0.1,
      performanceMetrics: PerformanceMetrics(
        realTimeFactor: 0.5,
        audioDuration: 0.2,
        processingTime: 0.1,
        thermalState: .nominal
      )
    )

    SettingsManager.shared.voiceCommandsEnabled = false
    let processed = PostProcessor().process(result)
    XCTAssertEqual(processed, "hello world")
  }

  func testSharedMemoryPCMRoundTrip() throws {
    let samples: [Float] = [0.0, 0.25, -0.5, 1.0]
    let name = try SharedMemoryPCM.write(samples: samples)
    defer { SharedMemoryPCM.remove(name: name) }
    let read = try SharedMemoryPCM.read(name: name, sampleCount: samples.count)
    XCTAssertEqual(read, samples)
  }

  func testCapturedAudioSharedBufferDuration() {
    let handle = PCMBufferHandle(shmName: "voicey_pcm_test", sampleCount: 16_000, sampleRate: 16_000)
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
}
