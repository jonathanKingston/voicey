import Foundation
import os

/// App-wide loggers using os.Logger for proper system integration
enum AppLogger {
  private static let subsystem = Bundle.main.bundleIdentifier ?? "work.voicey.Voicey"

  static let audio = Logger(subsystem: subsystem, category: "audio")
  static let transcription = Logger(subsystem: subsystem, category: "transcription")
  static let output = Logger(subsystem: subsystem, category: "output")
  // swiftlint:disable:next identifier_name
  static let ui = Logger(subsystem: subsystem, category: "ui")
  static let general = Logger(subsystem: subsystem, category: "general")
  static let model = Logger(subsystem: subsystem, category: "model")
}

// Global function for convenience - logs to general category
func log(_ message: String) {
  AppLogger.general.info("\(message)")
}

/// Debug print that outputs directly to terminal (visible when running from command line)
/// Use this for important debug info that should always be visible
func debugPrint(_ message: String, category: String = "DEBUG") {
  let formatter = ISO8601DateFormatter()
  let timestamp = formatter.string(from: Date())
  AppLogger.general.debug("[\(category, privacy: .public)] \(message, privacy: .public)")
  print("[\(timestamp)] [\(category)] \(message)")
  fflush(stdout)  // Ensure immediate output
}
