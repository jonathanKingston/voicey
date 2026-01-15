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
        case .tiny: return "Fastest, lower accuracy (~40MB)"
        case .base: return "Balanced speed and accuracy (~80MB)"
        case .small: return "Better accuracy, slower (~250MB)"
        case .medium: return "Best accuracy, slowest (~800MB)"
        }
    }
    
    var diskSize: Int64 {
        switch self {
        case .tiny: return 40_000_000
        case .base: return 80_000_000
        case .small: return 250_000_000
        case .medium: return 800_000_000
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
    
    /// Returns the path to a model if it exists, checking WhisperKit's nested directory structure
    func modelPath(for model: WhisperModel) -> String? {
        // WhisperKit stores models in: models/argmaxinc/whisperkit-coreml/{model_id}/
        let whisperKitPath = modelsDirectory
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml")
            .appendingPathComponent(model.whisperKitModelId)
        
        // Check if the model directory exists and has config.json (indicates complete download)
        let configPath = whisperKitPath.appendingPathComponent("config.json")
        if fileManager.fileExists(atPath: configPath.path) {
            return whisperKitPath.path
        }
        
        // Also check the direct path (legacy/alternative location)
        let directPath = modelsDirectory.appendingPathComponent(model.whisperKitModelId)
        let directConfigPath = directPath.appendingPathComponent("config.json")
        if fileManager.fileExists(atPath: directConfigPath.path) {
            return directPath.path
        }
        
        return nil
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
        
        let task = Task { @MainActor in
            do {
                // Use WhisperKit to download the model
                let modelURL = modelsDirectory
                
                // Create a temporary WhisperKit instance to trigger download
                _ = try await WhisperKit(
                    model: model.rawValue,
                    downloadBase: modelURL,
                    useBackgroundDownloadSession: false
                )
                
                // Reload downloaded models list
                loadDownloadedModels()
                downloadProgress[model] = 1.0
                isDownloading[model] = false
                downloadTasks[model] = nil
                
                NotificationManager.shared.showModelDownloadComplete(model: model)
            } catch {
                if !Task.isCancelled {
                    downloadError = "Download failed: \(error.localizedDescription)"
                    NotificationManager.shared.showModelDownloadFailed(reason: error.localizedDescription)
                }
                isDownloading[model] = false
                downloadProgress[model] = 0
                downloadTasks[model] = nil
            }
        }
        
        downloadTasks[model] = task
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
