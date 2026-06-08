import AVFoundation
import Darwin
import Foundation
import Speech

enum AppleSpeechPreset: String, Sendable {
  case offline
  case live

  var speechPreset: SpeechTranscriber.Preset {
    switch self {
    case .offline:
      return .offlineTranscription
    case .live:
      return .progressiveLiveTranscription
    }
  }
}

struct AppleSpeechTranscriptionResult: Sendable {
  let text: String
  let localeIdentifier: String
  let processingSeconds: Double
  let audioSeconds: Double
  let realTimeFactor: Double
}

enum AppleSpeechTranscriberError: LocalizedError {
  case unsupportedLocale(String)
  case emptyTranscript
  case assetInstallationFailed(String)

  var errorDescription: String? {
    switch self {
    case .unsupportedLocale(let locale):
      return "SpeechTranscriber does not support locale: \(locale)"
    case .emptyTranscript:
      return "SpeechTranscriber returned an empty transcript"
    case .assetInstallationFailed(let details):
      return "Failed to install Speech framework assets: \(details)"
    }
  }
}

enum AppleSpeechTranscriber {
  static func transcribe(
    audioURL: URL,
    locale: Locale,
    preset: AppleSpeechPreset,
    contextTerms: [String],
    warmupCount: Int
  ) async throws -> AppleSpeechTranscriptionResult {
    let resolvedLocale = try resolveLocale(locale)
    try await ensureAssets(locale: resolvedLocale, preset: preset)

    for _ in 0..<warmupCount {
      _ = try await transcribeOnce(
        audioURL: audioURL,
        locale: resolvedLocale,
        preset: preset,
        contextTerms: contextTerms
      )
    }

    let startedAt = CFAbsoluteTimeGetCurrent()
    let text = try await transcribeOnce(
      audioURL: audioURL,
      locale: resolvedLocale,
      preset: preset,
      contextTerms: contextTerms
    )
    let processingSeconds = CFAbsoluteTimeGetCurrent() - startedAt

    let audioSeconds = try audioDurationSeconds(for: audioURL)
    let realTimeFactor = audioSeconds > 0 ? processingSeconds / audioSeconds : 0

    return AppleSpeechTranscriptionResult(
      text: text,
      localeIdentifier: resolvedLocale.identifier(.bcp47),
      processingSeconds: processingSeconds,
      audioSeconds: audioSeconds,
      realTimeFactor: realTimeFactor
    )
  }

  private static func resolveLocale(_ locale: Locale) throws -> Locale {
    if let supported = SpeechTranscriber.supportedLocale(equivalentTo: locale) {
      return supported
    }
    throw AppleSpeechTranscriberError.unsupportedLocale(locale.identifier(.bcp47))
  }

  private static func ensureAssets(locale: Locale, preset: AppleSpeechPreset) async throws {
    let transcriber = SpeechTranscriber(locale: locale, preset: preset.speechPreset)
    guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
      return
    }
    do {
      try await request.downloadAndInstall()
    } catch {
      throw AppleSpeechTranscriberError.assetInstallationFailed(error.localizedDescription)
    }
  }

  private static func transcribeOnce(
    audioURL: URL,
    locale: Locale,
    preset: AppleSpeechPreset,
    contextTerms: [String]
  ) async throws -> String {
    let transcriber = SpeechTranscriber(locale: locale, preset: preset.speechPreset)
    let analyzer = SpeechAnalyzer(modules: [transcriber])

    if !contextTerms.isEmpty {
      var context = AnalysisContext()
      context.contextualStrings[AnalysisContext.ContextualStringsTag.general] = contextTerms
      try await analyzer.setContext(context)
    }

    let resultsTask = Task {
      var transcript = ""
      for try await result in transcriber.results {
        transcript += String(result.text.characters)
      }
      return transcript
    }

    let audioFile = try AVAudioFile(forReading: audioURL)
    if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
      try await analyzer.finalizeAndFinish(through: lastSample)
    } else {
      try analyzer.cancelAndFinishNow()
    }

    let transcript = try await resultsTask.value
    let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw AppleSpeechTranscriberError.emptyTranscript
    }
    return trimmed
  }

  private static func audioDurationSeconds(for audioURL: URL) throws -> Double {
    let audioFile = try AVAudioFile(forReading: audioURL)
    let sampleRate = audioFile.fileFormat.sampleRate
    guard sampleRate > 0 else { return 0 }
    return Double(audioFile.length) / sampleRate
  }
}
