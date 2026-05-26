import Foundation

/// Orchestrates prewarmed workers for Qwen multiprocess transcription.
actor VoiceyRuntimeSupervisor {
  static let shared = VoiceyRuntimeSupervisor()

  private let inferClient = QwenInferWorkerClient()
  private var inferReadyModel: SpeechModel?
  private var captureReady = false

  func prewarmAllWorkers(model: SpeechModel) async throws {
    try await prewarmInfer(model: model)
    try await prewarmCapture()
  }

  func prewarmInfer(model: SpeechModel) async throws {
    guard model.isQwenModel else {
      throw VoiceyRuntimeError.unsupportedModel(model.rawValue)
    }
    if inferReadyModel != model {
      inferClient.stop()
    }
    try await prewarmInferWithRetry(model: model)
    inferReadyModel = model
  }

  private func prewarmInferWithRetry(model: SpeechModel) async throws {
    do {
      try await inferClient.prewarm(model: model)
    } catch {
      AppLogger.runtime.warning(
        "Infer worker prewarm failed, retrying once: \(error.localizedDescription, privacy: .public)"
      )
      inferClient.stop()
      try await inferClient.prewarm(model: model)
    }
  }

  func prewarmCapture() async throws {
    guard let path = VoiceyRuntimeConfiguration.captureWorkerPath else {
      captureReady = true
      return
    }
    try VoiceyCaptureWorkerClient(path: path).prewarm()
    captureReady = true
  }

  func transcribe(samples: [Float], model: SpeechModel, warmupAlreadyDone: Bool) async throws -> TranscriptionResult {
    if !warmupAlreadyDone || inferReadyModel != model {
      try await prewarmInfer(model: model)
    }
    guard model.isQwenModel else {
      throw VoiceyRuntimeError.unsupportedModel(model.rawValue)
    }
    do {
      return try await inferClient.transcribe(samples: samples, model: model)
    } catch {
      AppLogger.runtime.warning(
        "Infer worker transcribe failed, retrying once: \(error.localizedDescription, privacy: .public)"
      )
      inferClient.stop()
      inferReadyModel = nil
      try await prewarmInfer(model: model)
      return try await inferClient.transcribe(samples: samples, model: model)
    }
  }

  func verifyInferWorkerHealth(model: SpeechModel) async -> Bool {
    guard model.isQwenModel, inferReadyModel == model else { return true }
    do {
      try await inferClient.ping()
      return true
    } catch {
      VoiceyRuntimeDiagnostics.recordInferWorkerError(error.localizedDescription)
      inferClient.stop()
      inferReadyModel = nil
      return false
    }
  }

  func shutdownGracefully() async {
    await inferClient.gracefulShutdown()
    inferReadyModel = nil
    captureReady = false
  }

  func shutdown() {
    inferClient.stop()
    inferReadyModel = nil
    captureReady = false
  }

  var isInferReady: Bool {
    inferReadyModel != nil
  }

  var isCaptureReady: Bool {
    captureReady
  }
}

enum VoiceyRuntimeError: LocalizedError {
  case unsupportedModel(String)

  var errorDescription: String? {
    switch self {
    case .unsupportedModel(let model):
      return "Multiprocess runtime does not support model: \(model)"
    }
  }
}
