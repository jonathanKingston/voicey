import Foundation

struct IncrementalTranscriptionSnapshot: Equatable {
  let partialText: String
  let pendingChunkCount: Int
  let isCatchingUp: Bool
}

final class IncrementalTranscriptionCoordinator: @unchecked Sendable {
  struct Configuration {
    let sampleRate: Double
    let pauseDuration: TimeInterval
    let safetyTailDuration: TimeInterval
    let minimumChunkDuration: TimeInterval
    let speechRMSThreshold: Float
    let trailingTrimDuration: TimeInterval
    let trailingTrimWindowDuration: TimeInterval
    let trailingTrimHopDuration: TimeInterval
    let minimumTrailingTrimDuration: TimeInterval

    static let `default` = Configuration(
      sampleRate: 16_000,
      pauseDuration: 1.0,
      safetyTailDuration: 0.25,
      minimumChunkDuration: 0.5,
      speechRMSThreshold: 0.01,
      trailingTrimDuration: 0.5,
      trailingTrimWindowDuration: 0.02,
      trailingTrimHopDuration: 0.01,
      minimumTrailingTrimDuration: 0.08
    )

    var pauseSampleCount: Int {
      Int(pauseDuration * sampleRate)
    }

    var safetyTailSampleCount: Int {
      Int(safetyTailDuration * sampleRate)
    }

    var minimumChunkSampleCount: Int {
      Int(minimumChunkDuration * sampleRate)
    }

    var trailingTrimSampleCount: Int {
      Int(trailingTrimDuration * sampleRate)
    }

    var trailingTrimWindowSampleCount: Int {
      max(1, Int(trailingTrimWindowDuration * sampleRate))
    }

    var trailingTrimHopSampleCount: Int {
      max(1, Int(trailingTrimHopDuration * sampleRate))
    }

    var minimumTrailingTrimSampleCount: Int {
      Int(minimumTrailingTrimDuration * sampleRate)
    }
  }

  private struct AudioChunk {
    let id: Int
    let startSampleIndex: Int
    let samples: [Float]
  }

  private struct CompletedChunk {
    let chunk: AudioChunk
    let result: TranscriptionResult
  }

  private let configuration: Configuration
  private let transcribe: ([Float]) async throws -> TranscriptionResult
  private let onUpdate: (IncrementalTranscriptionSnapshot) async -> Void
  private let stateQueue = DispatchQueue(label: "work.voicey.incremental-transcription")

  private var generation = 0
  private var bufferedSamples: [Float] = []
  private var bufferStartSampleIndex = 0
  private var nextChunkID = 0
  private var hasDetectedSpeech = false
  private var silenceSampleCount = 0
  private var pendingChunks: [AudioChunk] = []
  private var completedChunks: [CompletedChunk] = []
  private var processingTask: Task<Void, Never>?
  private var isProcessingChunk = false
  private var firstError: Error?

  init(
    configuration: Configuration = .default,
    transcribe: @escaping ([Float]) async throws -> TranscriptionResult,
    onUpdate: @escaping (IncrementalTranscriptionSnapshot) async -> Void
  ) {
    self.configuration = configuration
    self.transcribe = transcribe
    self.onUpdate = onUpdate
  }

  func reset() {
    stateQueue.sync {
      generation += 1
      bufferedSamples.removeAll()
      bufferStartSampleIndex = 0
      nextChunkID = 0
      hasDetectedSpeech = false
      silenceSampleCount = 0
      pendingChunks.removeAll()
      completedChunks.removeAll()
      firstError = nil
      publishSnapshotLocked()
    }
  }

  func append(samples: [Float]) {
    guard !samples.isEmpty else { return }

    stateQueue.async { [weak self] in
      self?.appendLocked(samples)
    }
  }

  func cancel() {
    reset()
  }

  func flushAndFinish(applyTrailingTrimHeuristic: Bool) async throws -> TranscriptionResult {
    stateQueue.sync {
      sealRemainingAudioLocked(applyTrailingTrimHeuristic: applyTrailingTrimHeuristic)
      startProcessingIfNeededLocked()
      publishSnapshotLocked()
    }

    while isProcessing {
      do {
        try await Task.sleep(nanoseconds: 50_000_000)
      } catch {
        throw error
      }
    }

    if let error = stateQueue.sync(execute: { firstError }) {
      throw error
    }

    return stateQueue.sync {
      combinedResultLocked()
    }
  }

  private var isProcessing: Bool {
    stateQueue.sync {
      processingTask != nil || isProcessingChunk || !pendingChunks.isEmpty
    }
  }

  private func appendLocked(_ samples: [Float]) {
    bufferedSamples.append(contentsOf: samples)

    let level = rms(samples)
    if level > configuration.speechRMSThreshold {
      hasDetectedSpeech = true
      silenceSampleCount = 0
    } else if hasDetectedSpeech {
      silenceSampleCount += samples.count
    } else {
      trimLeadingSilenceLocked()
    }

    if sealPausedChunkIfNeededLocked() {
      startProcessingIfNeededLocked()
      publishSnapshotLocked()
    }
  }

  private func trimLeadingSilenceLocked() {
    let retainedSamples = configuration.safetyTailSampleCount
    guard bufferedSamples.count > retainedSamples else { return }

    let droppedSampleCount = bufferedSamples.count - retainedSamples
    bufferedSamples.removeFirst(droppedSampleCount)
    bufferStartSampleIndex += droppedSampleCount
  }

  private func sealPausedChunkIfNeededLocked() -> Bool {
    guard hasDetectedSpeech,
          silenceSampleCount >= configuration.pauseSampleCount else {
      return false
    }

    let sealSampleCount = bufferedSamples.count - configuration.safetyTailSampleCount
    guard sealSampleCount >= configuration.minimumChunkSampleCount else {
      return false
    }

    sealChunkLocked(sampleCount: sealSampleCount)
    hasDetectedSpeech = false
    silenceSampleCount = min(silenceSampleCount, bufferedSamples.count)
    return true
  }

  private func sealRemainingAudioLocked(applyTrailingTrimHeuristic: Bool) {
    guard bufferedSamples.count >= configuration.minimumChunkSampleCount else {
      bufferedSamples.removeAll()
      hasDetectedSpeech = false
      silenceSampleCount = 0
      return
    }

    var samplesToSeal = bufferedSamples
    if applyTrailingTrimHeuristic {
      samplesToSeal = trimTrailingLowEnergyAudio(samplesToSeal)
    }

    guard samplesToSeal.count >= configuration.minimumChunkSampleCount else {
      bufferedSamples.removeAll()
      hasDetectedSpeech = false
      silenceSampleCount = 0
      return
    }

    let chunk = AudioChunk(
      id: nextChunkID,
      startSampleIndex: bufferStartSampleIndex,
      samples: samplesToSeal
    )
    pendingChunks.append(chunk)
    nextChunkID += 1

    bufferedSamples.removeAll()
    bufferStartSampleIndex += samplesToSeal.count
    hasDetectedSpeech = false
    silenceSampleCount = 0
  }

  private func sealChunkLocked(sampleCount: Int) {
    let samples = Array(bufferedSamples.prefix(sampleCount))
    let chunk = AudioChunk(
      id: nextChunkID,
      startSampleIndex: bufferStartSampleIndex,
      samples: samples
    )

    pendingChunks.append(chunk)
    nextChunkID += 1
    bufferedSamples.removeFirst(sampleCount)
    bufferStartSampleIndex += sampleCount
  }

  private func startProcessingIfNeededLocked() {
    guard processingTask == nil, !pendingChunks.isEmpty else { return }

    let taskGeneration = generation
    processingTask = Task { [weak self] in
      await self?.processQueue(generation: taskGeneration)
    }
  }

  private func processQueue(generation taskGeneration: Int) async {
    while !Task.isCancelled {
      guard let chunk = nextPendingChunk(generation: taskGeneration) else {
        break
      }

      do {
        let result = try await transcribe(chunk.samples)
        await complete(chunk: chunk, result: result, generation: taskGeneration)
      } catch {
        await fail(error: error, generation: taskGeneration)
        break
      }
    }

    await finishProcessing(generation: taskGeneration)
  }

  private func nextPendingChunk(generation taskGeneration: Int) -> AudioChunk? {
    stateQueue.sync {
      guard generation == taskGeneration, firstError == nil, !pendingChunks.isEmpty else {
        return nil
      }

      isProcessingChunk = true
      return pendingChunks.removeFirst()
    }
  }

  private func complete(
    chunk: AudioChunk,
    result: TranscriptionResult,
    generation taskGeneration: Int
  ) async {
    await withCheckedContinuation { continuation in
      stateQueue.async { [weak self] in
        guard let self else {
          continuation.resume()
          return
        }

        if self.generation == taskGeneration {
          self.completedChunks.append(CompletedChunk(chunk: chunk, result: result))
          self.completedChunks.sort { $0.chunk.id < $1.chunk.id }
          self.isProcessingChunk = false
          self.publishSnapshotLocked()
        }

        continuation.resume()
      }
    }
  }

  private func fail(error: Error, generation taskGeneration: Int) async {
    await withCheckedContinuation { continuation in
      stateQueue.async { [weak self] in
        guard let self else {
          continuation.resume()
          return
        }

        if self.generation == taskGeneration {
          self.firstError = error
          self.pendingChunks.removeAll()
          self.isProcessingChunk = false
          self.publishSnapshotLocked()
        }

        continuation.resume()
      }
    }
  }

  private func finishProcessing(generation taskGeneration: Int) async {
    await withCheckedContinuation { continuation in
      stateQueue.async { [weak self] in
        guard let self else {
          continuation.resume()
          return
        }

        self.isProcessingChunk = false
        self.processingTask = nil

        if self.generation == taskGeneration {
          self.publishSnapshotLocked()
        } else if !self.pendingChunks.isEmpty {
          self.startProcessingIfNeededLocked()
        }

        continuation.resume()
      }
    }
  }

  private func publishSnapshotLocked() {
    let snapshot = IncrementalTranscriptionSnapshot(
      partialText: combinedTextLocked(),
      pendingChunkCount: pendingChunks.count + (isProcessingChunk ? 1 : 0),
      isCatchingUp: isProcessingChunk || !pendingChunks.isEmpty
    )

    Task {
      await onUpdate(snapshot)
    }
  }

  private func combinedTextLocked() -> String {
    completedChunks
      .map { $0.result.text.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }

  private func combinedResultLocked() -> TranscriptionResult {
    let text = combinedTextLocked()
    let segments = completedChunks.flatMap { completedChunk in
      adjustedSegments(for: completedChunk)
    }
    let processingTime = completedChunks.reduce(0) { $0 + $1.result.processingTime }
    let audioDuration = completedChunks.reduce(0) {
      $0 + Double($1.chunk.samples.count) / configuration.sampleRate
    }
    let realTimeFactor = audioDuration > 0 ? processingTime / audioDuration : 0
    let language = completedChunks.first?.result.language ?? "auto"
    let metrics = PerformanceMetrics(
      realTimeFactor: realTimeFactor,
      audioDuration: audioDuration,
      processingTime: processingTime,
      thermalState: ProcessInfo.processInfo.thermalState
    )

    return TranscriptionResult(
      text: text,
      segments: segments,
      language: language,
      processingTime: processingTime,
      performanceMetrics: metrics
    )
  }

  private func adjustedSegments(for completedChunk: CompletedChunk) -> [TranscriptionSegment] {
    let offset = Double(completedChunk.chunk.startSampleIndex) / configuration.sampleRate
    return completedChunk.result.segments.map { segment in
      TranscriptionSegment(
        text: segment.text,
        startTime: segment.startTime + offset,
        endTime: segment.endTime + offset,
        tokens: segment.tokens.map { token in
          TranscriptionToken(
            text: token.text,
            probability: token.probability,
            startTime: token.startTime + offset,
            endTime: token.endTime + offset
          )
        }
      )
    }
  }

  private func trimTrailingLowEnergyAudio(_ samples: [Float]) -> [Float] {
    guard !samples.isEmpty else { return samples }

    let maxTrimSamples = configuration.trailingTrimSampleCount
    let windowSamples = configuration.trailingTrimWindowSampleCount
    let hopSamples = configuration.trailingTrimHopSampleCount
    let minTrimSamples = configuration.minimumTrailingTrimSampleCount

    guard samples.count > windowSamples else { return samples }
    let boundedMaxTrim = min(maxTrimSamples, samples.count - windowSamples)
    guard boundedMaxTrim >= minTrimSamples else { return samples }

    let scanStart = samples.count - boundedMaxTrim
    var scanIndex = samples.count - windowSamples
    var keepEndIndex = samples.count

    while scanIndex >= scanStart {
      let windowRMS = rms(in: samples, start: scanIndex, count: windowSamples)
      if windowRMS > configuration.speechRMSThreshold {
        keepEndIndex = scanIndex + windowSamples
        break
      }
      scanIndex -= hopSamples
    }

    let trimmedSampleCount = samples.count - keepEndIndex
    guard trimmedSampleCount >= minTrimSamples else { return samples }

    AppLogger.audio.info(
      "IncrementalTranscription: Trimmed \(trimmedSampleCount) trailing low-energy samples"
    )
    return Array(samples.prefix(keepEndIndex))
  }

  private func rms(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }

    let sumSquares = samples.reduce(Float(0)) { partialResult, sample in
      partialResult + sample * sample
    }
    return sqrt(sumSquares / Float(samples.count))
  }

  private func rms(in samples: [Float], start: Int, count: Int) -> Float {
    guard start >= 0, count > 0, start + count <= samples.count else { return 0 }

    let window = samples[start..<(start + count)]
    let sumSquares = window.reduce(Float(0)) { partialResult, sample in
      partialResult + sample * sample
    }
    return sqrt(sumSquares / Float(count))
  }
}
