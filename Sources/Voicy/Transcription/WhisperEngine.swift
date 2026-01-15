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
    
    init() {}
    
    /// Pre-load a Whisper model for faster first transcription
    func preloadModel() async {
        guard !isLoading && whisperKit == nil else { return }
        
        let selectedModel = SettingsManager.shared.selectedModel
        guard ModelManager.shared.isDownloaded(selectedModel) else { return }
        
        do {
            try await loadModel(variant: selectedModel.rawValue)
            AppLogger.model.info("WhisperEngine: Model \(selectedModel.rawValue) preloaded successfully")
        } catch {
            AppLogger.model.error("WhisperEngine: Failed to preload model: \(error)")
        }
    }
    
    /// Load a Whisper model
    func loadModel(variant: String = "base.en") async throws {
        // Don't reload if already loaded with same variant
        if whisperKit != nil && loadedModelVariant == variant {
            return
        }
        
        guard !isLoading else { return }
        isLoading = true
        
        defer { isLoading = false }
        
        // Unload existing model
        whisperKit = nil
        loadedModelVariant = nil
        
        let modelURL = ModelManager.shared.modelsDirectory
        
        AppLogger.model.info("WhisperEngine: Loading model \(variant)...")
        let startTime = CFAbsoluteTimeGetCurrent()
        
        whisperKit = try await WhisperKit(
            model: variant,
            downloadBase: modelURL,
            useBackgroundDownloadSession: false
        )
        
        loadedModelVariant = variant
        let loadTime = CFAbsoluteTimeGetCurrent() - startTime
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
            try await loadModel(variant: selectedModel.rawValue)
        }
        
        guard let whisperKit = whisperKit else {
            throw WhisperError.noModelLoaded
        }
        
        AppLogger.transcription.info("WhisperEngine: Starting transcription of \(audioBuffer.count) samples...")
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
        let results = try await whisperKit.transcribe(
            audioArray: audioBuffer,
            decodeOptions: options
        )
        
        let processingTime = CFAbsoluteTimeGetCurrent() - startTime
        AppLogger.transcription.info("WhisperEngine: Transcription completed in \(String(format: "%.2f", processingTime))s")
        
        guard let result = results.first else {
            throw WhisperError.transcriptionFailed
        }
        
        // Convert WhisperKit results to our format
        var segments: [TranscriptionSegment] = []
        
        for segment in result.segments {
            var tokens: [TranscriptionToken] = []
            
            for word in segment.words ?? [] {
                tokens.append(TranscriptionToken(
                    text: word.word,
                    probability: word.probability,
                    startTime: TimeInterval(word.start),
                    endTime: TimeInterval(word.end)
                ))
            }
            
            segments.append(TranscriptionSegment(
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
