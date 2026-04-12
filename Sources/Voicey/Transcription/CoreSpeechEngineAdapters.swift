import Foundation
import VoiceyCore

extension WhisperEngine: DictationTranscriptionEngine {
  var identifier: String {
    "whisperkit"
  }

  var isReady: Bool {
    isModelLoaded
  }

  func preload(modelIdentifier: String) async throws {
    try await loadModel(variant: modelIdentifier)
  }

  func transcribe(samples: [Float]) async throws -> TranscriptionResult {
    try await transcribe(audioBuffer: samples)
  }
}

extension QwenEngine: DictationTranscriptionEngine {
  var identifier: String {
    "qwen-mlx"
  }

  var isReady: Bool {
    isModelLoaded
  }

  func preload(modelIdentifier: String) async throws {
    try await loadModel(variant: modelIdentifier)
  }

  func transcribe(samples: [Float]) async throws -> TranscriptionResult {
    try await transcribe(audioBuffer: samples)
  }
}

extension GraniteEngine: DictationTranscriptionEngine {
  var identifier: String {
    "granite-python"
  }

  var isReady: Bool {
    isModelLoaded
  }

  func preload(modelIdentifier: String) async throws {
    try await loadModel(variant: modelIdentifier)
  }

  func transcribe(samples: [Float]) async throws -> TranscriptionResult {
    try await transcribe(audioBuffer: samples)
  }
}
