import Foundation
import os

/// App-wide loggers using os.Logger for proper system integration
enum AppLogger {
  static let audio = Logger(subsystem: "work.voicey.Voicey", category: "audio")
  static let transcription = Logger(subsystem: "work.voicey.Voicey", category: "transcription")
  static let output = Logger(subsystem: "work.voicey.Voicey", category: "output")
  static let ui = Logger(subsystem: "work.voicey.Voicey", category: "ui")
  static let general = Logger(subsystem: "work.voicey.Voicey", category: "general")
  static let model = Logger(subsystem: "work.voicey.Voicey", category: "model")
}

// Global function for convenience - logs to general category
func log(_ message: String) {
  AppLogger.general.info("\(message)")
}

/// Debug print that outputs directly to terminal (visible when running from command line)
/// Use this for important debug info that should always be visible
func debugPrint(_ message: String, category: String = "DEBUG") {
  let timestamp = ISO8601DateFormatter().string(from: Date())
  print("[\(timestamp)] [\(category)] \(message)")
  fflush(stdout)  // Ensure immediate output
}
