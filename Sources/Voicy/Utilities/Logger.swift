import Foundation
import os

/// App-wide loggers using os.Logger for proper system integration
enum AppLogger {
    static let audio = Logger(subsystem: "com.voicy.app", category: "audio")
    static let transcription = Logger(subsystem: "com.voicy.app", category: "transcription")
    static let output = Logger(subsystem: "com.voicy.app", category: "output")
    static let ui = Logger(subsystem: "com.voicy.app", category: "ui")
    static let general = Logger(subsystem: "com.voicy.app", category: "general")
    static let model = Logger(subsystem: "com.voicy.app", category: "model")
}

// Global function for convenience - logs to general category
func log(_ message: String) {
    AppLogger.general.info("\(message)")
}
