import Foundation
import Qwen3ASR
import VoiceyCore
import os

/// Wrapper around native Swift MLX Qwen3-ASR models.
final class QwenEngine: @unchecked Sendable {
  private var qwenModel: Qwen3ASRModel?
  private var isLoading = false
  private var loadedModelVariant: String?

  private let minimumQwenMaxTokens = 448
  private let maximumQwenMaxTokens = 4096
  private let qwenTokensPerSecondEstimate = 8.0
  private let qwenTokenBuffer = 128
  /// Qwen single-pass MLX inference degrades on very long clips; segment beyond this.
  private let maxSinglePassAudioSeconds: Double = 120
  private let chunkAudioSeconds: Double = 60

  /// Callback to notify when model loading state changes
  var onLoadingStateChanged: ((Bool) -> Void)?

  /// Callback when performance issues are detected
  var onPerformanceIssue: ((PerformanceMetrics) -> Void)?

  private var recentRTFs: [Double] = []
  private let maxRTFHistory = 5

  var averageRTF: Double {
    guard !recentRTFs.isEmpty else { return 0 }
    return recentRTFs.reduce(0, +) / Double(recentRTFs.count)
  }

  var isSystemStruggling: Bool {
    guard recentRTFs.count >= 2 else { return false }
    let avgRTF = averageRTF
    let thermalState = ProcessInfo.processInfo.thermalState
    if avgRTF > 1.5 { return true }
    if thermalState == .critical || thermalState == .serious { return true }
    return false
  }

  var thermalState: ProcessInfo.ThermalState {
    ProcessInfo.processInfo.thermalState
  }

  init() {}

  func preloadModel() async {
    let modelToLoad = SettingsManager.shared.selectedModel
    guard modelToLoad.isQwenModel else { return }

    if qwenModel != nil && loadedModelVariant == modelToLoad.rawValue {
      return
    }

    if isLoading {
      while isLoading {
        try? await Task.sleep(nanoseconds: 100_000_000)
      }
      if qwenModel != nil && loadedModelVariant == modelToLoad.rawValue {
        return
      }
    }

    guard ModelManager.shared.isDownloaded(modelToLoad) else {
      AppLogger.model.warning("QwenEngine: Selected Qwen model not downloaded, skipping preload")
      return
    }

    do {
      try await loadModel(variant: modelToLoad.rawValue)
      AppLogger.model.info("QwenEngine: Model \(modelToLoad.rawValue) preloaded successfully")
    } catch {
      AppLogger.model.error("QwenEngine: Failed to preload model: \(error)")
    }
  }

  func loadModel(variant: String) async throws {
    if qwenModel != nil && loadedModelVariant == variant {
      return
    }

    guard !isLoading else {
      while isLoading {
        try? await Task.sleep(nanoseconds: 100_000_000)
      }
      if qwenModel != nil && loadedModelVariant == variant {
        return
      }
      throw QwenError.modelNotReady
    }
    isLoading = true

    await MainActor.run {
      onLoadingStateChanged?(true)
    }

    defer {
      isLoading = false
      Task { @MainActor in
        onLoadingStateChanged?(false)
      }
    }

    qwenModel = nil
    loadedModelVariant = nil

    guard let selectedModel = SpeechModel(rawValue: variant), selectedModel.isQwenModel else {
      throw QwenError.invalidModel
    }
    guard ModelManager.shared.modelPath(for: selectedModel) != nil,
      let modelID = selectedModel.huggingFaceModelId
    else {
      throw QwenError.modelNotDownloaded
    }

    let loadedModel = try await Qwen3ASRModel.fromPretrained(modelId: modelID)
    qwenModel = loadedModel
    loadedModelVariant = variant
  }

  func unloadModel() {
    qwenModel = nil
    loadedModelVariant = nil
  }

  var isModelLoaded: Bool {
    qwenModel != nil
  }

  func transcribe(
    audioBuffer: [Float],
    decoderContext: String? = nil
  ) async throws -> TranscriptionResult {
    if qwenModel == nil {
      let selectedModel = SettingsManager.shared.selectedModel
      guard selectedModel.isQwenModel else {
        throw QwenError.invalidModel
      }
      guard ModelManager.shared.isDownloaded(selectedModel) else {
        throw QwenError.modelNotDownloaded
      }
      try await loadModel(variant: selectedModel.rawValue)
    }

    guard let qwenModel else {
      throw QwenError.modelNotReady
    }

    let thermalStateBefore = ProcessInfo.processInfo.thermalState
    let audioDuration = Double(audioBuffer.count) / 16000.0
    let startTime = CFAbsoluteTimeGetCurrent()

    if let decoderContext {
      AppLogger.transcription.info(
        "QwenEngine: Using transcription context (\(decoderContext.count) characters)"
      )
    }

    let transcribedText: String
    if audioDuration <= maxSinglePassAudioSeconds {
      transcribedText = transcribeSinglePass(
        qwenModel: qwenModel,
        audioBuffer: audioBuffer,
        decoderContext: decoderContext
      )
    } else {
      let chunkSampleCount = Int(chunkAudioSeconds * 16000)
      var parts: [String] = []
      var offset = 0
      let chunkCount = Int(ceil(audioDuration / chunkAudioSeconds))
      let chunkSeconds = Int(chunkAudioSeconds)
      AppLogger.transcription.info(
        "QwenEngine: Long clip (\(String(format: "%.1f", audioDuration))s); transcribing in \(chunkCount) × \(chunkSeconds)s segments"
      )
      while offset < audioBuffer.count {
        let end = min(offset + chunkSampleCount, audioBuffer.count)
        let chunk = Array(audioBuffer[offset..<end])
        let chunkText = transcribeSinglePass(
          qwenModel: qwenModel,
          audioBuffer: chunk,
          decoderContext: decoderContext
        )
        if !chunkText.isEmpty {
          parts.append(chunkText)
        }
        offset = end
      }
      transcribedText = parts.joined(separator: " ")
    }

    let processingTime = CFAbsoluteTimeGetCurrent() - startTime
    let rtf = audioDuration > 0 ? processingTime / audioDuration : 0

    let metrics = PerformanceMetrics(
      realTimeFactor: rtf,
      audioDuration: audioDuration,
      processingTime: processingTime,
      thermalState: thermalStateBefore
    )

    recentRTFs.append(rtf)
    if recentRTFs.count > maxRTFHistory {
      recentRTFs.removeFirst()
    }

    if metrics.isStruggling {
      await MainActor.run {
        onPerformanceIssue?(metrics)
      }
    }

    if transcribedText.isEmpty {
      AppLogger.transcription.warning(
        "QwenEngine: Empty transcript after stripping steering echo / chunk merge"
      )
    }

    return TranscriptionResult(
      text: transcribedText,
      segments: [],
      language: "auto",
      processingTime: processingTime,
      performanceMetrics: metrics
    )
  }

  private func transcribeSinglePass(
    qwenModel: Qwen3ASRModel,
    audioBuffer: [Float],
    decoderContext: String?
  ) -> String {
    let audioDuration = Double(audioBuffer.count) / 16000.0
    let tokenBudget = Int(ceil(audioDuration * qwenTokensPerSecondEstimate)) + qwenTokenBuffer
    let maxTokens = min(maximumQwenMaxTokens, max(minimumQwenMaxTokens, tokenBudget))

    AppLogger.transcription.info(
      "QwenEngine: Transcribing \(String(format: "%.1f", audioDuration))s audio with maxTokens=\(maxTokens)"
    )
    let rawText = qwenModel.transcribe(
      audio: audioBuffer,
      sampleRate: 16000,
      language: nil,
      maxTokens: maxTokens,
      context: decoderContext
    )
    let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    let stripped = TranscriptionGlossary.strippingEchoedDecoderContext(trimmed, decoderContext: decoderContext)
    if stripped.isEmpty, !trimmed.isEmpty {
      AppLogger.transcription.warning(
        "QwenEngine: Model echoed decoder context instead of speech; treating segment as empty"
      )
    }
    return stripped
  }

  func resetPerformanceTracking() {
    recentRTFs.removeAll()
  }
}

enum QwenError: LocalizedError {
  case invalidModel
  case modelNotDownloaded
  case modelNotReady

  var errorDescription: String? {
    switch self {
    case .invalidModel:
      return "Invalid Qwen model variant"
    case .modelNotDownloaded:
      return "Qwen model is not downloaded"
    case .modelNotReady:
      return "Qwen model is not loaded"
    }
  }
}
