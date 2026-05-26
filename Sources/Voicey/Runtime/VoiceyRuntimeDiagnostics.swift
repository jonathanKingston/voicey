import Foundation
import os

/// Support-facing runtime state for infer-worker issues.
enum VoiceyRuntimeDiagnostics {
  private static let lock = NSLock()
  private static var lastInferWorkerErrorStorage: String?
  private static var lastInferWorkerReadyAt: Date?
  private static var lastInferWorkerModelID: String?
  private static var workerProcessID: Int32?

  static var lastInferWorkerError: String? {
    lock.lock()
    defer { lock.unlock() }
    return lastInferWorkerErrorStorage
  }

  static func recordInferWorkerError(_ message: String) {
    lock.lock()
    lastInferWorkerErrorStorage = message
    lock.unlock()
    AppLogger.runtime.error("Infer worker: \(message, privacy: .public)")
  }

  static func recordInferWorkerReady(model: SpeechModel, processID: Int32?) {
    lock.lock()
    lastInferWorkerErrorStorage = nil
    lastInferWorkerReadyAt = Date()
    lastInferWorkerModelID = model.rawValue
    workerProcessID = processID
    lock.unlock()
    AppLogger.runtime.info(
      "Infer worker ready model=\(model.rawValue, privacy: .public) pid=\(processID ?? -1, privacy: .public)"
    )
  }

  static func recordInferWorkerStopped(exitStatus: Int32?) {
    lock.lock()
    workerProcessID = nil
    lock.unlock()
    if let exitStatus {
      AppLogger.runtime.info("Infer worker exited status=\(exitStatus, privacy: .public)")
    }
  }

  static func userFacingLoadFailureMessage() -> String {
    if let detail = lastInferWorkerError, !detail.isEmpty {
      return L10n.Runtime.inferWorkerStartFailedDetail(detail)
    }
    return L10n.Runtime.inferWorkerStartFailed
  }

  static func diagnosticReport(selectedModel: SpeechModel, inferReady: Bool) -> String {
    let envOverride = ProcessInfo.processInfo.environment["VOICEY_RUNTIME"] ?? "(none)"
    lock.lock()
    let lastError = lastInferWorkerErrorStorage
    let readyAt = lastInferWorkerReadyAt
    let readyModel = lastInferWorkerModelID
    let pid = workerProcessID
    lock.unlock()

    var lines: [String] = []
    lines.append("Voicey runtime diagnostics")
    lines.append("Bundle: \(Bundle.main.bundleIdentifier ?? "unknown")")
    lines.append("Selected model: \(selectedModel.rawValue)")
    lines.append("VOICEY_RUNTIME: \(envOverride)")
    lines.append(
      "Qwen infer worker enabled: \(VoiceyRuntimeConfiguration.usesInferWorker(for: selectedModel))"
    )
    lines.append("Infer worker ready (app): \(inferReady)")
    if let readyModel {
      lines.append("Infer worker loaded model: \(readyModel)")
    }
    if let pid {
      lines.append("Infer worker PID: \(pid)")
    }
    if let readyAt {
      lines.append("Infer worker ready at: \(ISO8601DateFormatter().string(from: readyAt))")
    }
    if let lastError {
      lines.append("Last infer worker error: \(lastError)")
    }
    return lines.joined(separator: "\n")
  }
}
