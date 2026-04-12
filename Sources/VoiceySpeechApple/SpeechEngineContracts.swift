import Foundation
import VoiceyCore

public struct SpeechTranscriptionResult: Equatable, Sendable {
  public let text: String
  public let language: String
  public let processingTime: TimeInterval
  public let modelIdentifier: String

  public init(
    text: String,
    language: String = "auto",
    processingTime: TimeInterval = 0,
    modelIdentifier: String = "unknown"
  ) {
    self.text = text
    self.language = language
    self.processingTime = processingTime
    self.modelIdentifier = modelIdentifier
  }
}

public protocol AppleSpeechEngine: Sendable {
  var identifier: String { get }
  var isReady: Bool { get }

  func preload(modelIdentifier: String) async throws
  func transcribe(samples: [Float]) async throws -> SpeechTranscriptionResult
}

public enum SpeechEngineFactoryError: LocalizedError {
  case unsupportedEngine(String)

  public var errorDescription: String? {
    switch self {
    case .unsupportedEngine(let identifier):
      return "Unsupported speech engine: \(identifier)"
    }
  }
}
