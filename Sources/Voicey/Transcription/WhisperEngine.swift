import Foundation
import WhisperKit
import os

/// Result from Whisper transcription including text and timing information
struct TranscriptionResult {
  let text: String
  let segments: [TranscriptionSegment]
  let language: String
  let processingTime: TimeInterval
}

struct TranscriptionSegment {
  let text: String
  let startTime: TimeInterval
  let endTime: TimeInterval
  let tokens: [TranscriptionToken]
}

struct TranscriptionToken {
  let text: String
  let probability: Float
  let startTime: TimeInterval
  let endTime: TimeInterval
}

/// Wrapper around WhisperKit for on-device speech-to-text
final class WhisperEngine {
  private var whisperKit: WhisperKit?
  private var isLoading = false
  private var loadedModelVariant: String?

  /// Callback to notify when model loading state changes
  var onLoadingStateChanged: ((Bool) -> Void)?

  init() {}

  /// Pre-load a Whisper model for faster first transcription
  func preloadModel() async {
    guard !isLoading && whisperKit == nil else { return }

    let selectedModel = SettingsManager.shared.selectedModel
    debugPrint("🎯 Selected model: \(selectedModel.rawValue)", category: "MODEL")
    debugPrint(
      "📋 Downloaded models: \(ModelManager.shared.downloadedModels.map { $0.rawValue })",
      category: "MODEL")

    guard ModelManager.shared.isDownloaded(selectedModel) else {
      debugPrint("⚠️ Selected model not downloaded, skipping preload", category: "MODEL")
      return
    }

    do {
      try await loadModel(variant: selectedModel.rawValue)
      debugPrint("✅ Model '\(selectedModel.rawValue)' preloaded successfully", category: "MODEL")
      AppLogger.model.info("WhisperEngine: Model \(selectedModel.rawValue) preloaded successfully")
    } catch {
      debugPrint("❌ Model preload failed: \(error)", category: "MODEL")
      AppLogger.model.error("WhisperEngine: Failed to preload model: \(error)")
    }
  }

  /// Load a Whisper model
  func loadModel(variant: String = "base.en") async throws {
    // Don't reload if already loaded with same variant
    if whisperKit != nil && loadedModelVariant == variant {
      AppLogger.model.info("WhisperEngine: Model \(variant) already loaded, skipping")
      return
    }

    guard !isLoading else {
      AppLogger.model.info("WhisperEngine: Already loading a model, skipping")
      return
    }
    isLoading = true

    // Notify that loading started
    await MainActor.run {
      onLoadingStateChanged?(true)
    }

    defer {
      isLoading = false
      Task { @MainActor in
        onLoadingStateChanged?(false)
      }
    }

    // Unload existing model
    whisperKit = nil
    loadedModelVariant = nil

    // Find the selected model enum to get its actual path
    guard let selectedModel = WhisperModel(rawValue: variant) else {
      AppLogger.model.error("WhisperEngine: Unknown model variant '\(variant)'")
      throw WhisperError.failedToLoadModel
    }

    // Get the actual path on disk (handles naming convention migrations)
    guard let modelPath = ModelManager.shared.modelPath(for: selectedModel) else {
      AppLogger.model.error("WhisperEngine: Model '\(variant)' not found on disk")
      throw WhisperError.noModelLoaded
    }

    debugPrint("📂 Model path: \(modelPath)", category: "MODEL")
    debugPrint(
      "⏳ Loading model '\(variant)' (first run may take 1-3 minutes for CoreML compilation)...",
      category: "MODEL")
    AppLogger.model.info("WhisperEngine: Loading model '\(variant)' from \(modelPath)")

    let startTime = CFAbsoluteTimeGetCurrent()

    do {
      // Use WhisperKitConfig with explicit modelFolder to load from disk
      // Setting download: false prevents any network requests
      let config = WhisperKitConfig(
        model: variant,
        modelFolder: modelPath,  // Explicit path to model folder
        download: false,  // Don't try to download anything
        useBackgroundDownloadSession: false
      )

      whisperKit = try await WhisperKit(config)
    } catch {
      debugPrint("❌ Failed to load model: \(error)", category: "MODEL")
      AppLogger.model.error("WhisperEngine: Failed to load model '\(variant)': \(error)")
      AppLogger.model.error("WhisperEngine: Error details: \(String(describing: error))")
      throw error
    }

    loadedModelVariant = variant
    let loadTime = CFAbsoluteTimeGetCurrent() - startTime
    debugPrint("✅ Model loaded in \(String(format: "%.1f", loadTime))s", category: "MODEL")
    AppLogger.model.info("WhisperEngine: Model loaded in \(String(format: "%.2f", loadTime))s")
  }

  /// Unload the current model to free memory
  func unloadModel() {
    whisperKit = nil
    loadedModelVariant = nil
  }

  /// Check if a model is currently loaded
  var isModelLoaded: Bool {
    whisperKit != nil
  }

  /// Transcribe audio samples (16kHz mono float32)
  func transcribe(audioBuffer: [Float]) async throws -> TranscriptionResult {
    // Load model if not loaded
    if whisperKit == nil {
      let selectedModel = SettingsManager.shared.selectedModel
      debugPrint("🔄 Loading model for transcription: \(selectedModel.rawValue)", category: "MODEL")

      guard ModelManager.shared.isDownloaded(selectedModel) else {
        debugPrint("❌ Model '\(selectedModel.rawValue)' not downloaded!", category: "MODEL")
        throw WhisperError.noModelLoaded
      }

      try await loadModel(variant: selectedModel.rawValue)
    }

    guard let whisperKit = whisperKit else {
      throw WhisperError.noModelLoaded
    }

    AppLogger.transcription.info(
      "WhisperEngine: Starting transcription of \(audioBuffer.count) samples...")
    let startTime = CFAbsoluteTimeGetCurrent()

    // Configure transcription options - simplified for speed
    let options = DecodingOptions(
      verbose: SettingsManager.shared.enableDetailedLogging,
      task: .transcribe,
      language: "en",
      temperatureFallbackCount: 1,  // Reduced for speed
      sampleLength: 224,
      usePrefillPrompt: true,
      usePrefillCache: true,
      skipSpecialTokens: true,
      withoutTimestamps: false,
      wordTimestamps: false  // Disabled for speed, we don't really need word-level timing
    )

    // Perform transcription
    AppLogger.transcription.info(
      "WhisperEngine: Calling whisperKit.transcribe() with \(audioBuffer.count) samples...")

    let results = try await whisperKit.transcribe(
      audioArray: audioBuffer,
      decodeOptions: options
    )

    let processingTime = CFAbsoluteTimeGetCurrent() - startTime
    AppLogger.transcription.info(
      "WhisperEngine: Transcription completed in \(String(format: "%.2f", processingTime))s")

    AppLogger.transcription.info("WhisperEngine: Got \(results.count) result(s)")

    guard let result = results.first else {
      AppLogger.transcription.error("WhisperEngine: No results returned from transcription")
      throw WhisperError.transcriptionFailed
    }

    AppLogger.transcription.info("WhisperEngine: Raw text: \"\(result.text)\"")
    AppLogger.transcription.info(
      "WhisperEngine: Segments: \(result.segments.count), Language: \(result.language)")

    // Convert WhisperKit results to our format
    var segments: [TranscriptionSegment] = []

    for segment in result.segments {
      var tokens: [TranscriptionToken] = []

      for word in segment.words ?? [] {
        tokens.append(
          TranscriptionToken(
            text: word.word,
            probability: word.probability,
            startTime: TimeInterval(word.start),
            endTime: TimeInterval(word.end)
          ))
      }

      segments.append(
        TranscriptionSegment(
          text: segment.text,
          startTime: TimeInterval(segment.start),
          endTime: TimeInterval(segment.end),
          tokens: tokens
        ))
    }

    let fullText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    AppLogger.transcription.info("WhisperEngine: Result: \"\(fullText)\"")

    return TranscriptionResult(
      text: fullText,
      segments: segments,
      language: result.language,
      processingTime: processingTime
    )
  }
}

// MARK: - Errors

enum WhisperError: LocalizedError {
  case failedToLoadModel
  case noModelLoaded
  case transcriptionFailed
  case engineDeallocated

  var errorDescription: String? {
    switch self {
    case .failedToLoadModel:
      return "Failed to load the Whisper model"
    case .noModelLoaded:
      return "No transcription model is loaded"
    case .transcriptionFailed:
      return "Transcription failed"
    case .engineDeallocated:
      return "Whisper engine was deallocated"
    }
  }
}
