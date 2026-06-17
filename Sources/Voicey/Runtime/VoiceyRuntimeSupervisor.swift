import Foundation

/// Orchestrates prewarmed workers for Qwen infer-worker transcription.
actor VoiceyRuntimeSupervisor {
  static let shared = VoiceyRuntimeSupervisor()

  private let inferClient = QwenInferWorkerClient()
  private let rustSupervisor = VoiceyRustSupervisorClient()
  private var inferReadyModel: SpeechModel?
  private var captureReady = false

  private var usesRustSupervisor: Bool {
    VoiceyRuntimeConfiguration.useRustSupervisor
      && VoiceyRuntimeConfiguration.rustSupervisorPath != nil
  }

  func prewarmAllWorkers(model: SpeechModel) async throws {
    try await prewarmInfer(model: model)
    try await prewarmCapture()
  }

  func prewarmInfer(model: SpeechModel) async throws {
    guard model.isQwenModel else {
      throw VoiceyRuntimeError.unsupportedModel(model.rawValue)
    }
    if inferReadyModel != model {
      if usesRustSupervisor {
        rustSupervisor.stop()
      } else {
        inferClient.stop()
      }
    }
    try await prewarmInferWithRetry(model: model)
    inferReadyModel = model
  }

  private func prewarmInferWithRetry(model: SpeechModel) async throws {
    do {
      if usesRustSupervisor {
        try await rustSupervisor.prewarmInfer(model: model)
      } else {
        try await inferClient.prewarm(model: model)
      }
    } catch {
      AppLogger.runtime.warning(
        "Infer prewarm failed, retrying once: \(error.localizedDescription, privacy: .public)"
      )
      if usesRustSupervisor {
        rustSupervisor.stop()
        try await rustSupervisor.prewarmInfer(model: model)
      } else {
        inferClient.stop()
        try await inferClient.prewarm(model: model)
      }
    }
  }

  func prewarmCapture() async throws {
    if VoiceyRuntimeConfiguration.useRustCaptureHotPath {
      try await VoiceyCaptureWorkerSession.shared.prewarm()
      captureReady = true
      return
    }

    if usesRustSupervisor {
      try await rustSupervisor.prewarmCapture()
      captureReady = true
      return
    }

    guard let path = VoiceyRuntimeConfiguration.captureWorkerPath else {
      captureReady = true
      return
    }
    try VoiceyCaptureWorkerClient(path: path).prewarm()
    captureReady = true
  }

  func transcribe(
    capturedAudio: CapturedAudio,
    model: SpeechModel,
    warmupAlreadyDone: Bool,
    decoderContext: String? = nil,
    language: String? = nil
  ) async throws -> TranscriptionResult {
    if !warmupAlreadyDone || inferReadyModel != model {
      try await prewarmInfer(model: model)
    }
    guard model.isQwenModel else {
      throw VoiceyRuntimeError.unsupportedModel(model.rawValue)
    }
    do {
      switch capturedAudio {
      case .sharedBuffer(let handle):
        if usesRustSupervisor {
          return try await rustSupervisor.transcribe(
            pcmHandle: handle,
            model: model,
            decoderContext: decoderContext,
            language: language
          )
        }
        return try await inferClient.transcribe(
          pcmHandle: handle,
          model: model,
          decoderContext: decoderContext,
          language: language
        )
      case .inMemory(let samples):
        if usesRustSupervisor {
          return try await rustSupervisor.transcribe(
            samples: samples,
            model: model,
            decoderContext: decoderContext,
            language: language
          )
        }
        return try await inferClient.transcribe(
          samples: samples,
          model: model,
          decoderContext: decoderContext,
          language: language
        )
      }
    } catch {
      AppLogger.runtime.warning(
        "Infer transcribe failed, retrying once: \(error.localizedDescription, privacy: .public)"
      )
      if usesRustSupervisor {
        rustSupervisor.stop()
      } else {
        inferClient.stop()
      }
      inferReadyModel = nil
      try await prewarmInfer(model: model)
      switch capturedAudio {
      case .sharedBuffer(let handle):
        if usesRustSupervisor {
          return try await rustSupervisor.transcribe(
            pcmHandle: handle,
            model: model,
            decoderContext: decoderContext,
            language: language
          )
        }
        return try await inferClient.transcribe(
          pcmHandle: handle,
          model: model,
          decoderContext: decoderContext,
          language: language
        )
      case .inMemory(let samples):
        if usesRustSupervisor {
          return try await rustSupervisor.transcribe(
            samples: samples,
            model: model,
            decoderContext: decoderContext,
            language: language
          )
        }
        return try await inferClient.transcribe(
          samples: samples,
          model: model,
          decoderContext: decoderContext,
          language: language
        )
      }
    }
  }

  func transcribe(
    samples: [Float],
    model: SpeechModel,
    warmupAlreadyDone: Bool,
    decoderContext: String? = nil,
    language: String? = nil
  ) async throws -> TranscriptionResult {
    if !warmupAlreadyDone || inferReadyModel != model {
      try await prewarmInfer(model: model)
    }
    guard model.isQwenModel else {
      throw VoiceyRuntimeError.unsupportedModel(model.rawValue)
    }
    do {
      if usesRustSupervisor {
        return try await rustSupervisor.transcribe(
          samples: samples,
          model: model,
          decoderContext: decoderContext,
          language: language
        )
      }
      return try await inferClient.transcribe(
        samples: samples,
        model: model,
        decoderContext: decoderContext,
        language: language
      )
    } catch {
      AppLogger.runtime.warning(
        "Infer transcribe failed, retrying once: \(error.localizedDescription, privacy: .public)"
      )
      if usesRustSupervisor {
        rustSupervisor.stop()
      } else {
        inferClient.stop()
      }
      inferReadyModel = nil
      try await prewarmInfer(model: model)
      if usesRustSupervisor {
        return try await rustSupervisor.transcribe(
          samples: samples,
          model: model,
          decoderContext: decoderContext,
          language: language
        )
      }
      return try await inferClient.transcribe(
        samples: samples,
        model: model,
        decoderContext: decoderContext,
        language: language
      )
    }
  }

  func verifyInferWorkerHealth(model: SpeechModel) async -> Bool {
    guard model.isQwenModel, inferReadyModel == model else { return true }
    do {
      if usesRustSupervisor {
        try await rustSupervisor.ping()
      } else {
        try await inferClient.ping()
      }
      return true
    } catch {
      VoiceyRuntimeDiagnostics.recordInferWorkerError(error.localizedDescription)
      if usesRustSupervisor {
        rustSupervisor.stop()
      } else {
        inferClient.stop()
      }
      inferReadyModel = nil
      return false
    }
  }

  /// Stop Qwen infer / supervisor only. Keeps mic capture and fetch workers alive for non-Qwen backends.
  func shutdownInferWorkers() async {
    if usesRustSupervisor {
      rustSupervisor.stop()
    } else {
      await inferClient.gracefulShutdown()
    }
    inferReadyModel = nil
  }

  func shutdownGracefully() async {
    await shutdownInferWorkers()
    VoiceyCaptureWorkerSession.shared.stop()
    VoiceyFetchWorkerSession.shared.stop()
    VoiceyTextWorkerSession.shared.stop()
    captureReady = false
  }

  func shutdown() {
    if usesRustSupervisor {
      rustSupervisor.stop()
    } else {
      inferClient.stop()
    }
    VoiceyCaptureWorkerSession.shared.stop()
    VoiceyFetchWorkerSession.shared.stop()
    VoiceyTextWorkerSession.shared.stop()
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
