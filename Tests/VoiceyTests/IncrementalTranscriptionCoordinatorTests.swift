@testable import Voicey
import XCTest

final class IncrementalTranscriptionCoordinatorTests: XCTestCase {
  // A short, fast configuration so tests run with small sample counts.
  private func makeConfiguration() -> IncrementalTranscriptionConfiguration {
    IncrementalTranscriptionConfiguration(
      sampleRate: 1_000,
      pauseDuration: 0.1,          // 100 samples of trailing silence seals a chunk
      safetyTailDuration: 0.02,    // 20 samples retained after a seal
      minimumChunkDuration: 0.05,  // 50 samples minimum to seal
      speechRMSThreshold: 0.01,
      trailingTrimDuration: 0.1,
      trailingTrimWindowDuration: 0.02,
      trailingTrimHopDuration: 0.01,
      minimumTrailingTrimDuration: 0.02
    )
  }

  private func speech(_ count: Int, amplitude: Float = 0.5) -> [Float] {
    // Alternating +/- amplitude yields a non-trivial RMS above threshold.
    (0..<count).map { $0.isMultiple(of: 2) ? amplitude : -amplitude }
  }

  private func silence(_ count: Int) -> [Float] {
    [Float](repeating: 0, count: count)
  }

  private func result(_ text: String) -> TranscriptionResult {
    TranscriptionResult(
      text: text,
      segments: [],
      language: "en",
      processingTime: 0,
      performanceMetrics: PerformanceMetrics(
        realTimeFactor: 0,
        audioDuration: 0,
        processingTime: 0,
        thermalState: .nominal
      )
    )
  }

  /// A pause between two utterances should produce two ordered chunks whose
  /// transcriptions are concatenated in capture order.
  func testPauseSealsOrderedChunks() async throws {
    let config = makeConfiguration()
    let callCount = Atomic(0)
    let coordinator = IncrementalTranscriptionCoordinator(
      configuration: config,
      transcribe: { _ in
        let index = callCount.increment()
        return self.result(index == 1 ? "hello" : "world")
      },
      onUpdate: { _ in }
    )

    // First utterance, then a pause long enough to seal, then a second utterance.
    coordinator.append(samples: speech(200))
    coordinator.append(samples: silence(config.pauseSampleCount + config.safetyTailSampleCount))
    coordinator.append(samples: speech(200))

    let combined = try await coordinator.flushAndFinish(applyTrailingTrimHeuristic: false)
    XCTAssertEqual(combined.text, "hello world")
    XCTAssertEqual(callCount.value, 2)
  }

  /// flushAndFinish on a single utterance (no internal pause) yields one chunk.
  func testFlushTranscribesSingleUtterance() async throws {
    let coordinator = IncrementalTranscriptionCoordinator(
      configuration: makeConfiguration(),
      transcribe: { _ in self.result("single") },
      onUpdate: { _ in }
    )

    coordinator.append(samples: speech(300))
    let combined = try await coordinator.flushAndFinish(applyTrailingTrimHeuristic: false)
    XCTAssertEqual(combined.text, "single")
  }

  /// A transcription error during a sealed chunk surfaces from flushAndFinish.
  func testErrorPropagatesFromFlush() async {
    let coordinator = IncrementalTranscriptionCoordinator(
      configuration: makeConfiguration(),
      transcribe: { _ in throw TranscriptionError.transcriptionFailed("boom") },
      onUpdate: { _ in }
    )

    coordinator.append(samples: speech(300))
    do {
      _ = try await coordinator.flushAndFinish(applyTrailingTrimHeuristic: false)
      XCTFail("Expected flushAndFinish to throw")
    } catch {
      // Expected.
    }
  }

  /// Audio shorter than the minimum chunk duration produces empty output rather
  /// than calling the transcribe closure.
  func testSubMinimumAudioProducesNoChunks() async throws {
    let called = Atomic(0)
    let coordinator = IncrementalTranscriptionCoordinator(
      configuration: makeConfiguration(),
      transcribe: { _ in
        _ = called.increment()
        return self.result("should-not-happen")
      },
      onUpdate: { _ in }
    )

    coordinator.append(samples: speech(10)) // below minimumChunkSampleCount (50)
    let combined = try await coordinator.flushAndFinish(applyTrailingTrimHeuristic: false)
    XCTAssertEqual(combined.text, "")
    XCTAssertEqual(called.value, 0)
  }

  /// cancel() ends in-flight chunk processing so flush does not wait on a stale transcribe.
  func testCancelDuringActiveTranscriptionDiscardsInFlightWork() async throws {
    let config = makeConfiguration()
    let gate = TranscriptionGate()
    let coordinator = IncrementalTranscriptionCoordinator(
      configuration: config,
      transcribe: { _ in
        await gate.waitUntilReleased()
        return self.result("stale")
      },
      onUpdate: { _ in }
    )

    coordinator.append(samples: speech(300))
    coordinator.append(samples: silence(config.pauseSampleCount + config.safetyTailSampleCount))
    await gate.waitUntilEntered()
    coordinator.cancel()
    await gate.release()

    let combined = try await coordinator.flushAndFinish(applyTrailingTrimHeuristic: false)
    XCTAssertEqual(combined.text, "")
  }

  /// cancel() drops sealed chunks still waiting in the queue behind an in-flight transcribe.
  func testCancelClearsQueuedChunksBehindInFlightTranscription() async throws {
    let config = makeConfiguration()
    let called = Atomic(0)
    let gate = TranscriptionGate()
    let coordinator = IncrementalTranscriptionCoordinator(
      configuration: config,
      transcribe: { _ in
        _ = called.increment()
        await gate.waitUntilReleased()
        return self.result("stale")
      },
      onUpdate: { _ in }
    )

    coordinator.append(samples: speech(200))
    coordinator.append(samples: silence(config.pauseSampleCount + config.safetyTailSampleCount))
    coordinator.append(samples: speech(200))
    await gate.waitUntilEntered()
    coordinator.cancel()
    await gate.release()

    let combined = try await coordinator.flushAndFinish(applyTrailingTrimHeuristic: false)
    XCTAssertEqual(combined.text, "")
    XCTAssertEqual(called.value, 1, "Queued chunk should not start after cancel")
  }

  /// A stale processing task finishing after cancel() must not nil out a newer generation's task.
  func testStaleFinishProcessingDoesNotClobberNewGeneration() async throws {
    let config = makeConfiguration()
    let staleGate = TranscriptionGate()
    let freshGate = TranscriptionGate()
    let transcribeCalls = Atomic(0)
    let coordinator = IncrementalTranscriptionCoordinator(
      configuration: config,
      transcribe: { _ in
        let call = transcribeCalls.increment()
        if call == 1 {
          await staleGate.waitUntilReleased()
          return self.result("stale")
        }
        await freshGate.waitUntilReleased()
        return self.result("fresh")
      },
      onUpdate: { _ in }
    )

    coordinator.append(samples: speech(200))
    coordinator.append(samples: silence(config.pauseSampleCount + config.safetyTailSampleCount))
    await staleGate.waitUntilEntered()
    coordinator.cancel()

    coordinator.append(samples: speech(200))
    coordinator.append(samples: silence(config.pauseSampleCount + config.safetyTailSampleCount))
    await waitUntil("fresh transcribe to start") { transcribeCalls.value >= 2 }
    await freshGate.waitUntilEntered()

    // Flush the new generation while its chunk is still in flight; flush must
    // keep waiting for it. Run concurrently so the gates can be released below
    // *while flush is polling* — that is the window in which a clobber would
    // make flush observe no work and return early (dropping the fresh chunk).
    async let flushed = coordinator.flushAndFinish(applyTrailingTrimHeuristic: false)

    // Let the stale task finish first: its finishProcessing must not clear the
    // fresh generation's processingTask/isProcessingChunk.
    await staleGate.release()
    try await Task.sleep(nanoseconds: 100_000_000)

    // Now let the fresh chunk complete so flush returns its text.
    await freshGate.release()

    let combined = try await flushed
    XCTAssertEqual(combined.text, "fresh")
  }

  /// reset() clears buffered audio so a subsequent flush returns empty output.
  func testResetClearsPendingAudio() async throws {
    let called = Atomic(0)
    let coordinator = IncrementalTranscriptionCoordinator(
      configuration: makeConfiguration(),
      transcribe: { _ in
        _ = called.increment()
        return self.result("stale")
      },
      onUpdate: { _ in }
    )

    coordinator.append(samples: speech(300))
    coordinator.reset()
    let combined = try await coordinator.flushAndFinish(applyTrailingTrimHeuristic: false)
    XCTAssertEqual(combined.text, "")
    XCTAssertEqual(called.value, 0)
  }
}

private func waitUntil(
  _ description: String,
  timeoutNanoseconds: UInt64 = 5_000_000_000,
  pollNanoseconds: UInt64 = 10_000_000,
  condition: @escaping () -> Bool
) async {
  let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
  while !condition() {
    if DispatchTime.now().uptimeNanoseconds > deadline {
      XCTFail("Timed out waiting for \(description)")
      return
    }
    try? await Task.sleep(nanoseconds: pollNanoseconds)
  }
}

/// Blocks the fake transcribe closure until `release()` so tests can call `cancel()` mid-flight.
private actor TranscriptionGate {
  private var transcribeEntered = false
  private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func waitUntilEntered() async {
    if transcribeEntered { return }
    await withCheckedContinuation { enteredWaiters.append($0) }
  }

  func waitUntilReleased() async {
    transcribeEntered = true
    enteredWaiters.forEach { $0.resume() }
    enteredWaiters.removeAll()
    await withCheckedContinuation { releaseWaiters.append($0) }
  }

  func release() {
    releaseWaiters.forEach { $0.resume() }
    releaseWaiters.removeAll()
  }
}

/// Minimal thread-safe counter for use inside the coordinator's escaping
/// closures, which may run on its internal serial queue.
private final class Atomic: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Int

  init(_ value: Int) { stored = value }

  var value: Int {
    lock.lock(); defer { lock.unlock() }
    return stored
  }

  @discardableResult
  func increment() -> Int {
    lock.lock(); defer { lock.unlock() }
    stored += 1
    return stored
  }
}
