import AVFoundation
import Darwin
import Foundation
import Speech

enum AppleSpeechPreset: String, Sendable {
  case offline
  case live

  /// Canonical SpeechTranscriber preset names (macOS 26 SDK, post-rename).
  var speechPreset: SpeechTranscriber.Preset {
    switch self {
    case .offline:
      return .transcription
    case .live:
      return .progressiveTranscription
    }
  }

  var speechPresetName: String {
    switch self {
    case .offline:
      return "transcription"
    case .live:
      return "progressiveTranscription"
    }
  }

  static func parse(_ raw: String) -> AppleSpeechPreset? {
    switch raw {
    case "offline", "transcription":
      return .offline
    case "live", "progressiveTranscription", "progressiveLiveTranscription":
      return .live
    default:
      return AppleSpeechPreset(rawValue: raw)
    }
  }
}

struct AppleSpeechAssetProbe: Sendable {
  let localeIdentifier: String
  let resolvedLocaleIdentifier: String
  let presetName: String
  let assetStatus: String
  let localeInstalled: Bool
  let localeSupported: Bool
  let installedLocaleIdentifiers: [String]
  let platformVersion: String
}

struct AppleSpeechTranscriptionResult: Sendable {
  let text: String
  let localeIdentifier: String
  let presetName: String
  let assetStatus: String
  let localeInstalled: Bool
  let platformVersion: String
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
  static func probeAssets(
    locale: Locale,
    preset: AppleSpeechPreset
  ) async throws -> AppleSpeechAssetProbe {
    let resolvedLocale = try resolveLocale(locale)
    let transcriber = SpeechTranscriber(locale: resolvedLocale, preset: preset.speechPreset)
    let snapshot = await assetSnapshot(for: transcriber, locale: resolvedLocale, preset: preset)
    return AppleSpeechAssetProbe(
      localeIdentifier: locale.identifier(.bcp47),
      resolvedLocaleIdentifier: resolvedLocale.identifier(.bcp47),
      presetName: preset.speechPresetName,
      assetStatus: snapshot.statusLabel,
      localeInstalled: snapshot.localeInstalled,
      localeSupported: snapshot.localeSupported,
      installedLocaleIdentifiers: snapshot.installedLocaleIdentifiers,
      platformVersion: platformVersionString()
    )
  }

  static func transcribe(
    audioURL: URL,
    locale: Locale,
    preset: AppleSpeechPreset,
    contextTerms: [String],
    warmupCount: Int
  ) async throws -> AppleSpeechTranscriptionResult {
    let resolvedLocale = try resolveLocale(locale)
    let transcriber = SpeechTranscriber(locale: resolvedLocale, preset: preset.speechPreset)
    let snapshot = try await ensureAssets(transcriber: transcriber, locale: resolvedLocale, preset: preset)

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
      presetName: preset.speechPresetName,
      assetStatus: snapshot.statusLabel,
      localeInstalled: snapshot.localeInstalled,
      platformVersion: platformVersionString(),
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

  private struct AssetSnapshot: Sendable {
    let statusLabel: String
    let localeInstalled: Bool
    let localeSupported: Bool
    let installedLocaleIdentifiers: [String]
  }

  private static func assetSnapshot(
    for transcriber: SpeechTranscriber,
    locale: Locale,
    preset: AppleSpeechPreset
  ) async -> AssetSnapshot {
    let status = await AssetInventory.status(forModules: [transcriber])
    let installed = await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) }.sorted()
    let supported = await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) }.sorted()
    let localeID = locale.identifier(.bcp47)
    return AssetSnapshot(
      statusLabel: String(describing: status),
      localeInstalled: installed.contains(localeID),
      localeSupported: supported.contains(localeID),
      installedLocaleIdentifiers: installed
    )
  }

  private static func ensureAssets(
    transcriber: SpeechTranscriber,
    locale: Locale,
    preset: AppleSpeechPreset
  ) async throws -> AssetSnapshot {
    var snapshot = await assetSnapshot(for: transcriber, locale: locale, preset: preset)
    guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
      return snapshot
    }
    do {
      try await request.downloadAndInstall()
      snapshot = await assetSnapshot(for: transcriber, locale: locale, preset: preset)
      return snapshot
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
        guard result.isFinal else { continue }
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

  private static func platformVersionString() -> String {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
  }
}
