import Foundation

/// Reference to PCM samples in a temp-dir `voicey_pcm_*.pcm` file (see `voicey-pcm` crate).
struct PCMBufferHandle: Sendable, Equatable {
  let shmName: String
  /// Number of samples to transcribe (slice length when `sampleOffset` > 0).
  let sampleCount: Int
  let sampleRate: Int
  /// Start index within the PCM file (protocol `sample_offset`, default 0).
  let sampleOffset: Int

  init(shmName: String, sampleCount: Int, sampleRate: Int, sampleOffset: Int = 0) {
    self.shmName = shmName
    self.sampleCount = sampleCount
    self.sampleRate = sampleRate
    self.sampleOffset = max(0, sampleOffset)
  }

  var durationSeconds: TimeInterval {
    guard sampleRate > 0 else { return 0 }
    return Double(sampleCount) / Double(sampleRate)
  }

  func remove() {
    SharedMemoryPCM.remove(name: shmName)
  }
}

/// Captured audio from `AudioCaptureManager`: in-memory samples or a shared PCM file handle.
enum CapturedAudio: Sendable {
  case inMemory([Float])
  case sharedBuffer(PCMBufferHandle)

  var sampleCount: Int {
    switch self {
    case .inMemory(let samples):
      return samples.count
    case .sharedBuffer(let handle):
      return handle.sampleCount
    }
  }

  var durationSeconds: TimeInterval {
    switch self {
    case .inMemory(let samples):
      return Double(samples.count) / 16_000.0
    case .sharedBuffer(let handle):
      return handle.durationSeconds
    }
  }

  /// Loads float samples when a caller still needs an in-memory buffer (in-process infer, benchmarks).
  func inMemorySamples() throws -> [Float] {
    switch self {
    case .inMemory(let samples):
      return samples
    case .sharedBuffer(let handle):
      return try SharedMemoryPCM.read(
        name: handle.shmName,
        sampleCount: handle.sampleCount,
        sampleOffset: handle.sampleOffset
      )
    }
  }

  func removeSharedBufferIfNeeded() {
    if case .sharedBuffer(let handle) = self {
      handle.remove()
    }
  }

  /// Bar heights for the transcription overlay progress view.
  func waveformEnvelope() -> [Float] {
    switch self {
    case .inMemory(let samples):
      return AudioWaveformEnvelope.normalizedBars(from: samples)
    case .sharedBuffer(let handle):
      if let bars = try? AudioWaveformEnvelope.normalizedBars(fromSharedBuffer: handle) {
        return bars
      }
      return Array(repeating: 0.08, count: AudioWaveformEnvelope.displayBarCount)
    }
  }

  var finishesViaSharedPCMHandleTranscription: Bool {
    UtteranceTranscriptionFinish.route(for: self) == .sharedPCMHandle
  }
}
