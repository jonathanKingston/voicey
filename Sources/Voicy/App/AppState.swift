import Foundation
import Combine

/// Represents the current state of the transcription process
enum TranscriptionState: Equatable {
    /// No transcription in progress
    case idle
    
    /// Currently recording audio
    /// - Parameter startTime: When recording started (for duration tracking)
    case recording(startTime: Date)
    
    /// Processing recorded audio
    case processing
    
    /// Transcription completed successfully
    /// - Parameter text: The transcribed text
    case completed(text: String)
    
    /// Transcription failed
    /// - Parameter message: Error description
    case error(message: String)
    
    // MARK: - Convenience Properties
    
    /// Whether we're currently recording
    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }
    
    /// Whether we're currently processing
    var isProcessing: Bool {
        if case .processing = self { return true }
        return false
    }
    
    /// Whether we're in an active state (recording or processing)
    var isActive: Bool {
        switch self {
        case .recording, .processing:
            return true
        case .idle, .completed, .error:
            return false
        }
    }
    
    /// Recording duration if currently recording
    var recordingDuration: TimeInterval? {
        if case .recording(let startTime) = self {
            return Date().timeIntervalSince(startTime)
        }
        return nil
    }
    
    /// Display text for the current state
    var displayText: String {
        switch self {
        case .idle:
            return "Ready"
        case .recording:
            return "Listening..."
        case .processing:
            return "Transcribing..."
        case .completed:
            return "Done"
        case .error(let message):
            return "Error: \(message)"
        }
    }
}

/// Holds the observable application state
final class AppState: ObservableObject {
    @Published var transcriptionState: TranscriptionState = .idle
    @Published var audioLevel: Float = 0.0
    @Published var currentModel: WhisperModel = SettingsManager.shared.selectedModel
    @Published var lastTranscription: String = ""
    
    // MARK: - Convenience Accessors
    
    /// Whether we're currently recording (delegates to transcriptionState)
    var isRecording: Bool {
        transcriptionState.isRecording
    }
}
