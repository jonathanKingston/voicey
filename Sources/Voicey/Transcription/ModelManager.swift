import Foundation
import Combine
import WhisperKit
import os

/// Available Whisper model variants
enum WhisperModel: String, CaseIterable, Identifiable {
    // Note: WhisperKit uses underscores for turbo variants (large-v3_turbo, not large-v3-turbo)
    case largeTurbo = "large-v3_turbo"
    case large = "large-v3"
    case distilLarge = "distil-large-v3"
    case small = "small.en"
    case base = "base.en"
    case tiny = "tiny.en"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .largeTurbo: return "Large v3 Turbo"
        case .large: return "Large v3"
        case .distilLarge: return "Distil Large v3"
        case .small: return "Small (English)"
        case .base: return "Base (English)"
        case .tiny: return "Tiny (English)"
        }
    }
    
    var description: String {
        switch self {
        case .largeTurbo: return "Fast & accurate, 8x faster than Large (~1.5GB)"
        case .large: return "Maximum accuracy, slower (~3GB)"
        case .distilLarge: return "Distilled model, fast & accurate (~800MB)"
        case .small: return "Balanced speed/accuracy (~250MB)"
        case .base: return "Fast, basic accuracy (~80MB)"
        case .tiny: return "Fastest, lowest accuracy (~40MB)"
        }
    }
    
    var isRecommended: Bool {
        self == .largeTurbo
    }
    
    var diskSize: Int64 {
        switch self {
        case .largeTurbo: return 1_500_000_000
        case .large: return 3_000_000_000
        case .distilLarge: return 800_000_000
        case .small: return 250_000_000
        case .base: return 80_000_000
        case .tiny: return 40_000_000
        }
    }
    
    var memoryUsage: Int64 {
        switch self {
        case .largeTurbo: return 3_000_000_000
        case .large: return 6_000_000_000
        case .distilLarge: return 2_000_000_000
        case .small: return 600_000_000
        case .base: return 200_000_000
        case .tiny: return 100_000_000
        }
    }
    
    /// WhisperKit model repository identifier (how WhisperKit names folders)
    var whisperKitModelId: String {
        switch self {
        case .largeTurbo: return "openai_whisper-large-v3_turbo"
        case .large: return "openai_whisper-large-v3"
        case .distilLarge: return "distil-whisper_distil-large-v3"
        case .small: return "openai_whisper-small.en"
        case .base: return "openai_whisper-base.en"
        case .tiny: return "openai_whisper-tiny.en"
        }
    }
}

/// Manages downloading, storing, and selecting Whisper models via WhisperKit
final class ModelManager: ObservableObject {
    static let shared = ModelManager()
    
    @Published var downloadProgress: [WhisperModel: Double] = [:]
    @Published var downloadedModels: Set<WhisperModel> = []
    @Published var isDownloading: [WhisperModel: Bool] = [:]
    @Published var downloadError: String?
    
    private let fileManager = FileManager.default
    private var downloadTasks: [WhisperModel: Task<Void, Never>] = [:]
    
    private init() {
        loadDownloadedModels()
    }
    
    // MARK: - Paths
    
    var modelsDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let voiceyDir = appSupport.appendingPathComponent("Voicey/Models", isDirectory: true)
        
        // Create directory if needed
        if !fileManager.fileExists(atPath: voiceyDir.path) {
            try? fileManager.createDirectory(at: voiceyDir, withIntermediateDirectories: true)
        }
        
        return voiceyDir
    }
    
    /// Returns the path to a model if it exists and is complete, checking WhisperKit's nested directory structure
    func modelPath(for model: WhisperModel) -> String? {
        // WhisperKit stores models in: models/argmaxinc/whisperkit-coreml/{model_id}/
        let whisperKitPath = modelsDirectory
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml")
            .appendingPathComponent(model.whisperKitModelId)
        
        // Check if the model directory exists and has all essential files
        let configPath = whisperKitPath.appendingPathComponent("config.json")
        guard fileManager.fileExists(atPath: configPath.path) else {
            return nil
        }
        
        // Verify essential model components exist with their weight files
        // A complete model must have MelSpectrogram, AudioEncoder, and TextDecoder
        let essentialComponents = ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"]
        
        for component in essentialComponents {
            let componentPath = whisperKitPath.appendingPathComponent(component)
            
            // Check directory exists
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: componentPath.path, isDirectory: &isDir), isDir.boolValue else {
                AppLogger.model.warning("Model incomplete: missing \(component)")
                return nil
            }
            
            // Check for compiled model (coremldata.bin) OR weights directory with weight.bin
            let coremlDataPath = componentPath.appendingPathComponent("coremldata.bin")
            let weightsPath = componentPath.appendingPathComponent("weights/weight.bin")
            
            let hasCoremlData = fileManager.fileExists(atPath: coremlDataPath.path)
            let hasWeights = fileManager.fileExists(atPath: weightsPath.path)
            
            // MelSpectrogram typically doesn't have weights (small model), but others do
            // At minimum, the directory should have model.mil or coremldata.bin
            let modelMilPath = componentPath.appendingPathComponent("model.mil")
            let hasModelMil = fileManager.fileExists(atPath: modelMilPath.path)
            
            if !hasCoremlData && !hasWeights && !hasModelMil {
                AppLogger.model.warning("Model incomplete: \(component) missing essential files")
                return nil
            }
        }
        
        return whisperKitPath.path
    }
    
    var hasDownloadedModel: Bool {
        !downloadedModels.isEmpty
    }
    
    // MARK: - Model Discovery
    
    func loadDownloadedModels() {
        downloadedModels.removeAll()
        
        for model in WhisperModel.allCases {
            if modelPath(for: model) != nil {
                downloadedModels.insert(model)
            }
        }
    }
    
    func isDownloaded(_ model: WhisperModel) -> Bool {
        // Always check fresh in case files changed
        return modelPath(for: model) != nil
    }
    
    func modelFileSize(_ model: WhisperModel) -> Int64? {
        guard let path = modelPath(for: model) else { return nil }
        return directorySize(at: URL(fileURLWithPath: path))
    }
    
    private func directorySize(at url: URL) -> Int64 {
        var size: Int64 = 0
        let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        while let fileURL = enumerator?.nextObject() as? URL {
            if let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                size += Int64(fileSize)
            }
        }
        return size
    }
    
    // MARK: - Download
    
    func downloadModel(_ model: WhisperModel) {
        guard !isDownloading[model, default: false] else { return }
        
        isDownloading[model] = true
        downloadProgress[model] = 0
        downloadError = nil
        
        AppLogger.model.info("Starting download of model: \(model.displayName)")
        
        let task = Task { @MainActor in
            do {
                AppLogger.model.info("Starting WhisperKit download with progress tracking...")
                
                // Use the proper WhisperKit.download static function with progress callback
                let modelFolder = try await WhisperKit.download(
                    variant: model.rawValue,
                    downloadBase: modelsDirectory,
                    useBackgroundSession: false,
                    progressCallback: { [weak self] progress in
                        Task { @MainActor in
                            let fraction = progress.fractionCompleted
                            self?.downloadProgress[model] = fraction
                            AppLogger.model.debug("Download progress: \(Int(fraction * 100))%")
                        }
                    }
                )
                
                AppLogger.model.info("Download completed to: \(modelFolder.path)")
                
                // Verify the download actually succeeded by checking for config.json
                if modelPath(for: model) != nil {
                    AppLogger.model.info("Model \(model.displayName) downloaded and verified successfully")
                    loadDownloadedModels()
                    downloadProgress[model] = 1.0
                    isDownloading[model] = false
                    downloadTasks[model] = nil
                    NotificationManager.shared.showModelDownloadComplete(model: model)
                } else {
                    // Download seemed to complete but files are missing
                    AppLogger.model.error("Model download completed but verification failed - files may be incomplete")
                    throw ModelDownloadError.verificationFailed
                }
            } catch {
                if !Task.isCancelled {
                    let errorMessage = Self.classifyDownloadError(error)
                    AppLogger.model.error("Model download failed: \(errorMessage) (underlying: \(error))")
                    downloadError = errorMessage
                    NotificationManager.shared.showModelDownloadFailed(reason: errorMessage)
                }
                isDownloading[model] = false
                downloadProgress[model] = 0
                downloadTasks[model] = nil
            }
        }
        
        downloadTasks[model] = task
    }
    
    /// Classify download errors into user-friendly messages
    private static func classifyDownloadError(_ error: Error) -> String {
        let errorString = error.localizedDescription.lowercased()
        let nsError = error as NSError
        
        // Check for network-related errors
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet:
                return "No internet connection. Please check your network and try again."
            case NSURLErrorTimedOut:
                return "Download timed out. Please check your network connection and try again."
            case NSURLErrorNetworkConnectionLost:
                return "Network connection was lost. Please try again."
            case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost:
                return "Cannot reach the model server. Please check your internet connection."
            case NSURLErrorSecureConnectionFailed:
                return "Secure connection failed. Please try again later."
            default:
                return "Network error: \(error.localizedDescription)"
            }
        }
        
        // Check for common error patterns in the message
        if errorString.contains("network") || errorString.contains("internet") || errorString.contains("connection") {
            return "Network error: Please check your internet connection and try again."
        }
        
        if errorString.contains("disk") || errorString.contains("space") || errorString.contains("storage") {
            return "Insufficient disk space. Please free up some storage and try again."
        }
        
        if errorString.contains("permission") || errorString.contains("access") {
            return "Permission denied. Please check app permissions."
        }
        
        // Check if it's our verification error
        if error is ModelDownloadError {
            return "Download incomplete. Please try again."
        }
        
        return "Download failed: \(error.localizedDescription)"
    }
    
    /// Custom errors for model management
    enum ModelDownloadError: LocalizedError {
        case verificationFailed
        case networkUnavailable
        
        var errorDescription: String? {
            switch self {
            case .verificationFailed:
                return "Model download verification failed"
            case .networkUnavailable:
                return "Network is unavailable"
            }
        }
    }
    
    func cancelDownload(_ model: WhisperModel) {
        downloadTasks[model]?.cancel()
        downloadTasks[model] = nil
        isDownloading[model] = false
        downloadProgress[model] = 0
    }
    
    // MARK: - Delete
    
    func deleteModel(_ model: WhisperModel) throws {
        // Delete from WhisperKit's nested path
        let whisperKitPath = modelsDirectory
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml")
            .appendingPathComponent(model.whisperKitModelId)
        
        if fileManager.fileExists(atPath: whisperKitPath.path) {
            try fileManager.removeItem(at: whisperKitPath)
        }
        
        // Also try direct path
        let directPath = modelsDirectory.appendingPathComponent(model.whisperKitModelId)
        if fileManager.fileExists(atPath: directPath.path) {
            try fileManager.removeItem(at: directPath)
        }
        
        downloadedModels.remove(model)
        downloadProgress[model] = 0
    }
    
    // MARK: - Formatting
    
    static func formatSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
