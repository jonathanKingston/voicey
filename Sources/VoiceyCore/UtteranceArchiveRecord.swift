import Foundation

/// How a dictation utterance ended when archived locally.
public enum UtteranceArchiveOutcome: String, Codable, Sendable, CaseIterable {
  case completed
  case emptyDelivery = "empty_delivery"
  case error
}

/// One retained dictation utterance (manifest line in `index.jsonl`).
public struct UtteranceArchiveRecord: Codable, Sendable, Equatable, Identifiable {
  public let id: UUID
  public let createdAt: Date
  public let outcome: UtteranceArchiveOutcome
  public let errorMessage: String?
  public let modelID: String
  public let languageID: String
  public let audioSeconds: Double
  /// Relative to the session archive root, e.g. `audio/{uuid}.wav`.
  public let audioPath: String
  /// Lossless container for replay, e.g. `wav_f32` (16 kHz mono IEEE float).
  public let audioFormat: String?
  public let rawText: String
  public let processedText: String
  public let partialTranscription: String?
  public let steeringTerms: [String]
  public let decoderContextSHA256: String?
  public let glossaryEnabled: Bool
  public let screenContextEnabled: Bool
  /// Relative path under archive root when screen context was captured.
  public let snapshotPath: String?
  public let targetAppBundleID: String?
  public let voiceyVersion: String?
  public let runtime: String?

  public init(
    id: UUID = UUID(),
    createdAt: Date = Date(),
    outcome: UtteranceArchiveOutcome,
    errorMessage: String? = nil,
    modelID: String,
    languageID: String,
    audioSeconds: Double,
    audioPath: String,
    audioFormat: String? = nil,
    rawText: String,
    processedText: String,
    partialTranscription: String? = nil,
    steeringTerms: [String],
    decoderContextSHA256: String? = nil,
    glossaryEnabled: Bool,
    screenContextEnabled: Bool,
    snapshotPath: String? = nil,
    targetAppBundleID: String? = nil,
    voiceyVersion: String? = nil,
    runtime: String? = nil
  ) {
    self.id = id
    self.createdAt = createdAt
    self.outcome = outcome
    self.errorMessage = errorMessage
    self.modelID = modelID
    self.languageID = languageID
    self.audioSeconds = audioSeconds
    self.audioPath = audioPath
    self.audioFormat = audioFormat
    self.rawText = rawText
    self.processedText = processedText
    self.partialTranscription = partialTranscription
    self.steeringTerms = steeringTerms
    self.decoderContextSHA256 = decoderContextSHA256
    self.glossaryEnabled = glossaryEnabled
    self.screenContextEnabled = screenContextEnabled
    self.snapshotPath = snapshotPath
    self.targetAppBundleID = targetAppBundleID
    self.voiceyVersion = voiceyVersion
    self.runtime = runtime
  }

  enum CodingKeys: String, CodingKey {
    case id
    case createdAt = "created_at"
    case outcome
    case errorMessage = "error_message"
    case modelID = "model_id"
    case languageID = "language_id"
    case audioSeconds = "audio_seconds"
    case audioPath = "audio_path"
    case audioFormat = "audio_format"
    case rawText = "raw_text"
    case processedText = "processed_text"
    case partialTranscription = "partial_transcription"
    case steeringTerms = "steering_terms"
    case decoderContextSHA256 = "decoder_context_sha256"
    case glossaryEnabled = "glossary_enabled"
    case screenContextEnabled = "screen_context_enabled"
    case snapshotPath = "snapshot_path"
    case targetAppBundleID = "app_bundle_id"
    case voiceyVersion = "voicey_version"
    case runtime
  }

  public var displayPreview: String {
    let candidate = processedText.trimmingCharacters(in: .whitespacesAndNewlines)
    if !candidate.isEmpty { return candidate }
    let raw = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    if !raw.isEmpty { return raw }
    return errorMessage ?? ""
  }
}

/// JSON snapshot payload stored beside audio for screen-context replay debugging.
public struct UtteranceArchiveScreenSnapshot: Codable, Sendable, Equatable {
  public let queryText: String
  public let corpusChunks: [String]

  public init(queryText: String, corpusChunks: [String]) {
    self.queryText = queryText
    self.corpusChunks = corpusChunks
  }

  public init(snapshot: ScreenContextSnapshot) {
    queryText = snapshot.queryText
    corpusChunks = snapshot.corpusChunks
  }

  enum CodingKeys: String, CodingKey {
    case queryText = "query_text"
    case corpusChunks = "corpus_chunks"
  }
}
