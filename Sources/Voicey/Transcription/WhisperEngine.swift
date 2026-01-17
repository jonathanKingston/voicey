import Foundation
import WhisperKit
import os

/// Result from Whisper transcription including text and timing information
struct TranscriptionResult {
  let text: String
  let segments: [TranscriptionSegment]
  let language: String
  let processingTime: TimeInterval
  let performanceMetrics: PerformanceMetrics
}

/// Performance metrics for transcription
struct PerformanceMetrics {
  /// Real-time factor: processing time / audio duration
  /// < 1.0 means faster than real-time
  /// > 1.0 means slower than real-time
  let realTimeFactor: Double

  /// Audio duration in seconds
  let audioDuration: TimeInterval

  /// Processing time in seconds
  let processingTime: TimeInterval

  /// System thermal state at time of transcription
  let thermalState: ProcessInfo.ThermalState

  /// Whether the system appears to be struggling
  var isStruggling: Bool {
    // Consider struggling if:
    // 1. RTF > 2.0 (taking twice as long as the audio duration)
    // 2. System is thermally throttled
    // 3. RTF > 1.0 and thermal state is serious/critical
    if realTimeFactor > 2.0 { return true }
    if thermalState == .critical { return true }
    if thermalState == .serious && realTimeFactor > 1.0 { return true }
    return false
  }

  /// Human-readable description of performance
  var description: String {
    let rtfStr = String(format: "%.2fx", realTimeFactor)
    let thermalStr: String
    switch thermalState {
    case .nominal: thermalStr = "nominal"
    case .fair: thermalStr = "fair"
    case .serious: thermalStr = "serious"
    case .critical: thermalStr = "critical"
    @unknown default: thermalStr = "unknown"
    }
    return "RTF: \(rtfStr), Thermal: \(thermalStr)"
  }

  /// Suggestion for improving performance
  var suggestion: String? {
    if thermalState == .critical || thermalState == .serious {
      return
        "System is running hot. Consider using a smaller model or letting the device cool down."
    }
    if realTimeFactor > 2.0 {
      return
        "Transcription is slow. Consider switching to a faster model like 'Small' for better performance."
    }
    if realTimeFactor > 1.5 {
      return "Transcription may be slow on longer recordings. A smaller model might help."
    }
    return nil
  }
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

  /// Callback when performance issues are detected
  var onPerformanceIssue: ((PerformanceMetrics) -> Void)?

  /// Rolling average of real-time factors for recent transcriptions
  private var recentRTFs: [Double] = []
  private let maxRTFHistory = 5

  /// Average RTF over recent transcriptions
  var averageRTF: Double {
    guard !recentRTFs.isEmpty else { return 0 }
    return recentRTFs.reduce(0, +) / Double(recentRTFs.count)
  }

  /// Whether recent transcriptions indicate the system is struggling
  var isSystemStruggling: Bool {
    guard recentRTFs.count >= 2 else { return false }
    let avgRTF = averageRTF
    let thermalState = ProcessInfo.processInfo.thermalState

    // Struggling if average RTF > 1.5 or thermal state is bad
    if avgRTF > 1.5 { return true }
    if thermalState == .critical || thermalState == .serious { return true }
    return false
  }

  /// Current system thermal state
  var thermalState: ProcessInfo.ThermalState {
    ProcessInfo.processInfo.thermalState
  }

  init() {}

  /// Pre-load a Whisper model for faster first transcription
  func preloadModel() async {
    guard !isLoading && whisperKit == nil else { return }

    var modelToLoad = SettingsManager.shared.selectedModel
    debugPrint("🎯 Selected model: \(modelToLoad.rawValue)", category: "MODEL")
    debugPrint(
      "📋 Downloaded models: \(ModelManager.shared.downloadedModels.map { $0.rawValue })",
      category: "MODEL")

    // If selected model isn't downloaded, fall back to best available model
    if !ModelManager.shared.isDownloaded(modelToLoad) {
      if let bestAvailable = Self.selectBestAvailableModel(from: ModelManager.shared.downloadedModels) {
        debugPrint("⚠️ Selected model not downloaded, falling back to \(bestAvailable.rawValue)", category: "MODEL")
        modelToLoad = bestAvailable
        // Update settings to reflect actual model being used
        SettingsManager.shared.selectedModel = bestAvailable
      } else {
        debugPrint("⚠️ No models downloaded, skipping preload", category: "MODEL")
        return
      }
    }

    do {
      try await loadModel(variant: modelToLoad.rawValue)
      debugPrint("✅ Model '\(modelToLoad.rawValue)' preloaded successfully", category: "MODEL")
      AppLogger.model.info("WhisperEngine: Model \(modelToLoad.rawValue) preloaded successfully")
    } catch {
      debugPrint("❌ Model preload failed: \(error)", category: "MODEL")
      AppLogger.model.error("WhisperEngine: Failed to preload model: \(error)")
    }
  }
  
  /// Select the best available model from downloaded models
  /// Prefers already-compiled models, then smaller/faster models for quick startup
  private static func selectBestAvailableModel(from models: Set<WhisperModel>) -> WhisperModel? {
    guard !models.isEmpty else { return nil }
    
    // First, check if any model is already compiled (will load fast)
    // Prefer quality model if it's already compiled
    let qualityFirst: [WhisperModel] = [.largeTurbo, .large, .distilLarge, .small, .base, .tiny]
    for model in qualityFirst {
      if models.contains(model) && ModelManager.shared.isLikelyCompiled(model) {
        debugPrint("🚀 Found already-compiled model: \(model.rawValue)", category: "MODEL")
        return model
      }
    }
    
    // No compiled models found - prefer smaller/faster models for quick first-time compilation
    // Quality model (largeTurbo) will be loaded in background and swapped in later
    let smallFirst: [WhisperModel] = [.tiny, .base, .small, .distilLarge, .large, .largeTurbo]
    for model in smallFirst {
      if models.contains(model) {
        debugPrint("📦 No compiled models found, using fastest to compile: \(model.rawValue)", category: "MODEL")
        return model
      }
    }
    
    // Fallback to any available model
    return models.first
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

    // Calculate audio duration (16kHz sample rate)
    let audioDuration = Double(audioBuffer.count) / 16000.0

    // Capture thermal state before processing
    let thermalStateBefore = ProcessInfo.processInfo.thermalState

    AppLogger.transcription.info(
      "WhisperEngine: Starting transcription of \(audioBuffer.count) samples (~\(String(format: "%.1f", audioDuration))s)..."
    )
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

    // Calculate performance metrics
    let rtf = audioDuration > 0 ? processingTime / audioDuration : 0
    let metrics = PerformanceMetrics(
      realTimeFactor: rtf,
      audioDuration: audioDuration,
      processingTime: processingTime,
      thermalState: thermalStateBefore
    )

    // Track RTF history
    recentRTFs.append(rtf)
    if recentRTFs.count > maxRTFHistory {
      recentRTFs.removeFirst()
    }

    AppLogger.transcription.info(
      "WhisperEngine: Transcription completed in \(String(format: "%.2f", processingTime))s (RTF: \(String(format: "%.2f", rtf)))"
    )

    // Log performance metrics
    debugPrint("📊 Performance: \(metrics.description)", category: "PERF")
    if let suggestion = metrics.suggestion {
      debugPrint("💡 \(suggestion)", category: "PERF")
    }

    // Notify if performance is poor
    if metrics.isStruggling {
      AppLogger.transcription.warning(
        "WhisperEngine: System appears to be struggling with transcription")
      await MainActor.run {
        onPerformanceIssue?(metrics)
      }
    }

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
      processingTime: processingTime,
      performanceMetrics: metrics
    )
  }

  /// Check current system performance state
  func checkSystemPerformance() -> (
    thermalState: ProcessInfo.ThermalState, avgRTF: Double, isStruggling: Bool
  ) {
    return (thermalState, averageRTF, isSystemStruggling)
  }

  /// Reset performance tracking (e.g., after switching models)
  func resetPerformanceTracking() {
    recentRTFs.removeAll()
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
