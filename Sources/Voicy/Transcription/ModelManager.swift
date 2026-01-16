import Foundation
import Combine
import WhisperKit

/// Available Whisper model variants
enum WhisperModel: String, CaseIterable, Identifiable {
    case tiny = "tiny.en"
    case base = "base.en"
    case small = "small.en"
    case medium = "medium.en"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .tiny: return "Tiny (English)"
        case .base: return "Base (English)"
        case .small: return "Small (English)"
        case .medium: return "Medium (English)"
        }
    }
    
    var description: String {
        switch self {
        case .tiny: return "Fastest, lower accuracy (~90MB)"
        case .base: return "Balanced speed and accuracy (~150MB)"
        case .small: return "Better accuracy, slower (~500MB)"
        case .medium: return "Best accuracy, slowest (~1.5GB)"
        }
    }
    
    /// Expected download size (approximate, used for progress estimation)
    var diskSize: Int64 {
        switch self {
        case .tiny: return 90_000_000      // ~90MB actual
        case .base: return 150_000_000     // ~150MB actual
        case .small: return 500_000_000    // ~500MB actual
        case .medium: return 1_500_000_000 // ~1.5GB actual
        }
    }
    
    var memoryUsage: Int64 {
        switch self {
        case .tiny: return 100_000_000
        case .base: return 200_000_000
        case .small: return 600_000_000
        case .medium: return 2_000_000_000
        }
    }
    
    /// WhisperKit model repository identifier
    var whisperKitModelId: String {
        // WhisperKit uses different naming convention
        switch self {
        case .tiny: return "openai_whisper-tiny.en"
        case .base: return "openai_whisper-base.en"
        case .small: return "openai_whisper-small.en"
        case .medium: return "openai_whisper-medium.en"
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
    @Published var downloadFailed: [WhisperModel: Bool] = [:]
    @Published var downloadErrorMessage: [WhisperModel: String] = [:]
    
    private let fileManager = FileManager.default
    private var downloadTasks: [WhisperModel: Task<Void, Never>] = [:]
    private var progressTimers: [WhisperModel: Timer] = [:]
    
    private init() {
        loadDownloadedModels()
    }
    
    // MARK: - Paths
    
    var modelsDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let voiceyDir = appSupport.appendingPathComponent("Voicey/Models", isDirectory: true)
        return voiceyDir
    }
    
    /// Ensures the models directory exists, creating it if necessary
    /// - Throws: If the directory cannot be created
    func ensureModelsDirectoryExists() throws {
        let dir = modelsDirectory
        if !fileManager.fileExists(atPath: dir.path) {
            AppLogger.model.info("ModelManager: Creating models directory at \(dir.path)")
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        }
    }
    
    /// Returns the path to a model if it exists, checking WhisperKit's nested directory structure
    func modelPath(for model: WhisperModel) -> String? {
        // WhisperKit stores models in: models/argmaxinc/whisperkit-coreml/{model_id}/
        let whisperKitPath = modelsDirectory
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml")
            .appendingPathComponent(model.whisperKitModelId)
        
        // Check if the model is complete (has config.json AND weights in encoder)
        if isModelComplete(at: whisperKitPath) {
            return whisperKitPath.path
        }
        
        // Also check the direct path (legacy/alternative location)
        let directPath = modelsDirectory.appendingPathComponent(model.whisperKitModelId)
        if isModelComplete(at: directPath) {
            return directPath.path
        }
        
        return nil
    }
    
    /// Validates that a model directory has all required files for WhisperKit to load
    private func isModelComplete(at modelDir: URL) -> Bool {
        // Must have config.json
        let configPath = modelDir.appendingPathComponent("config.json")
        guard fileManager.fileExists(atPath: configPath.path) else {
            return false
        }
        
        // Must have AudioEncoder.mlmodelc with weights (this is the largest component)
        let encoderWeights = modelDir
            .appendingPathComponent("AudioEncoder.mlmodelc")
            .appendingPathComponent("weights")
            .appendingPathComponent("weight.bin")
        guard fileManager.fileExists(atPath: encoderWeights.path) else {
            AppLogger.model.warning("ModelManager: Model at \(modelDir.path) missing AudioEncoder weights")
            return false
        }
        
        // Must have TextDecoder.mlmodelc (might not have separate weights folder for smaller models)
        let textDecoderDir = modelDir.appendingPathComponent("TextDecoder.mlmodelc")
        guard fileManager.fileExists(atPath: textDecoderDir.path) else {
            AppLogger.model.warning("ModelManager: Model at \(modelDir.path) missing TextDecoder")
            return false
        }
        
        // Check TextDecoder has either weights/weight.bin or model.mil
        let decoderWeights = textDecoderDir
            .appendingPathComponent("weights")
            .appendingPathComponent("weight.bin")
        let decoderMil = textDecoderDir.appendingPathComponent("model.mil")
        
        guard fileManager.fileExists(atPath: decoderWeights.path) || fileManager.fileExists(atPath: decoderMil.path) else {
            AppLogger.model.warning("ModelManager: Model at \(modelDir.path) has incomplete TextDecoder")
            return false
        }
        
        // Must have MelSpectrogram.mlmodelc
        let melSpectrogramDir = modelDir.appendingPathComponent("MelSpectrogram.mlmodelc")
        guard fileManager.fileExists(atPath: melSpectrogramDir.path) else {
            AppLogger.model.warning("ModelManager: Model at \(modelDir.path) missing MelSpectrogram")
            return false
        }
        
        return true
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
        guard fileManager.fileExists(atPath: url.path) else { return 0 }
        let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        while let fileURL = enumerator?.nextObject() as? URL {
            if let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                size += Int64(fileSize)
            }
        }
        return size
    }
    
    /// Gets the current download size for a model (includes both model dir and cache)
    private func currentDownloadSize(for model: WhisperModel) -> Int64 {
        let modelDir = modelsDirectory
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml")
            .appendingPathComponent(model.whisperKitModelId)
        
        let cacheDir = modelsDirectory
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml/.cache/huggingface/download")
            .appendingPathComponent(model.whisperKitModelId)
        
        return directorySize(at: modelDir) + directorySize(at: cacheDir)
    }
    
    /// Starts monitoring download progress by checking folder sizes
    private func startProgressMonitor(for model: WhisperModel) {
        // Stop any existing timer
        progressTimers[model]?.invalidate()
        
        let expectedSize = model.diskSize
        
        // Create timer on main thread
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            let currentSize = self.currentDownloadSize(for: model)
            let progress = min(Double(currentSize) / Double(expectedSize), 0.99) // Cap at 99% until complete
            
            DispatchQueue.main.async {
                self.downloadProgress[model] = progress
            }
            
            AppLogger.model.debug("ModelManager: Download progress for \(model.rawValue): \(Int(progress * 100))% (\(Self.formatSize(currentSize)) / \(Self.formatSize(expectedSize)))")
        }
        
        progressTimers[model] = timer
    }
    
    /// Stops the progress monitor for a model
    private func stopProgressMonitor(for model: WhisperModel) {
        progressTimers[model]?.invalidate()
        progressTimers[model] = nil
    }
    
    // MARK: - Download
    
    func downloadModel(_ model: WhisperModel) {
        guard !isDownloading[model, default: false] else { return }
        
        isDownloading[model] = true
        downloadProgress[model] = 0
        downloadError = nil
        downloadFailed[model] = false
        downloadErrorMessage[model] = nil
        
        AppLogger.model.info("ModelManager: Starting download for model \(model.rawValue)")
        AppLogger.model.info("ModelManager: Download destination: \(self.modelsDirectory.path)")
        
        // Start progress monitoring
        startProgressMonitor(for: model)
        
        let task = Task { @MainActor in
            defer {
                // Always stop progress monitor when done
                stopProgressMonitor(for: model)
            }
            
            do {
                // Ensure the models directory exists first
                try ensureModelsDirectoryExists()
                
                // Clean up any previous incomplete download
                cleanupIncompleteDownload(model)
                
                let modelURL = modelsDirectory
                AppLogger.model.info("ModelManager: Models directory confirmed at: \(modelURL.path)")
                
                AppLogger.model.info("ModelManager: Initializing WhisperKit with model: \(model.rawValue)")
                
                // Create a temporary WhisperKit instance to trigger download
                _ = try await WhisperKit(
                    model: model.rawValue,
                    downloadBase: modelURL,
                    useBackgroundDownloadSession: false
                )
                
                AppLogger.model.info("ModelManager: Download completed successfully for \(model.rawValue)")
                
                // Reload downloaded models list
                loadDownloadedModels()
                downloadProgress[model] = 1.0
                isDownloading[model] = false
                downloadFailed[model] = false
                downloadTasks[model] = nil
                
                NotificationManager.shared.showModelDownloadComplete(model: model)
            } catch {
                AppLogger.model.error("ModelManager: Download failed for \(model.rawValue): \(error)")
                AppLogger.model.error("ModelManager: Error details: \(String(describing: error))")
                
                if !Task.isCancelled {
                    let errorMsg = error.localizedDescription
                    downloadError = "Download failed: \(errorMsg)"
                    downloadFailed[model] = true
                    downloadErrorMessage[model] = errorMsg
                    NotificationManager.shared.showModelDownloadFailed(reason: errorMsg)
                }
                isDownloading[model] = false
                downloadProgress[model] = 0
                downloadTasks[model] = nil
            }
        }
        
        downloadTasks[model] = task
    }
    
    func cancelDownload(_ model: WhisperModel) {
        stopProgressMonitor(for: model)
        downloadTasks[model]?.cancel()
        downloadTasks[model] = nil
        isDownloading[model] = false
        downloadProgress[model] = 0
        // Don't mark as failed when user explicitly cancels
    }
    
    func clearFailedState(_ model: WhisperModel) {
        downloadFailed[model] = false
        downloadErrorMessage[model] = nil
    }
    
    /// Removes any incomplete/corrupted model files to allow a fresh download
    func cleanupIncompleteDownload(_ model: WhisperModel) {
        let whisperKitPath = modelsDirectory
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml")
            .appendingPathComponent(model.whisperKitModelId)
        
        let cachePath = modelsDirectory
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml/.cache/huggingface/download")
            .appendingPathComponent(model.whisperKitModelId)
        
        // Only cleanup if the model exists but is incomplete
        if fileManager.fileExists(atPath: whisperKitPath.path) && !isModelComplete(at: whisperKitPath) {
            AppLogger.model.info("ModelManager: Cleaning up incomplete model at \(whisperKitPath.path)")
            try? fileManager.removeItem(at: whisperKitPath)
        }
        
        // Also cleanup the download cache for this model
        if fileManager.fileExists(atPath: cachePath.path) {
            AppLogger.model.info("ModelManager: Cleaning up download cache at \(cachePath.path)")
            try? fileManager.removeItem(at: cachePath)
        }
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
