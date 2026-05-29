import Foundation

/// Reference to PCM samples in a temp-dir `voicey_pcm_*.pcm` file (see `voicey-pcm` crate).
struct PCMBufferHandle: Sendable, Equatable {
  let shmName: String
  let sampleCount: Int
  let sampleRate: Int

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
      return try SharedMemoryPCM.read(name: handle.shmName, sampleCount: handle.sampleCount)
    }
  }

  func removeSharedBufferIfNeeded() {
    if case .sharedBuffer(let handle) = self {
      handle.remove()
    }
  }
}
