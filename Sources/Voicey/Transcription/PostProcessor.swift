import Foundation
import os

/// Post-processes transcription output for punctuation, formatting, and voice commands
final class PostProcessor {
  private let textExpansions: [String: String]

  init() {
    self.textExpansions = TextCleanup.defaultTextExpansions
  }

  /// Get current voice commands settings (read fresh each time)
  private var voiceCommandsEnabled: Bool {
    SettingsManager.shared.voiceCommandsEnabled
  }

  private var voiceCommands: [VoiceCommand] {
    SettingsManager.shared.voiceCommands.filter { $0.enabled }
  }

  // MARK: - Processing

  func process(_ result: TranscriptionResult) -> String {
    var text = result.text

    AppLogger.transcription.info("PostProcessor: Input text: \"\(text)\"")

    // First, filter out noise words and artifacts
    text = filterNoise(text)

    AppLogger.transcription.info("PostProcessor: After noise filter: \"\(text)\"")

    // If the entire transcription was just noise, return empty
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      AppLogger.transcription.info(
        "PostProcessor: Text is empty after noise filter, returning empty")
      return ""
    }

    // Apply intelligent punctuation based on timing and segment analysis
    text = applyIntelligentPunctuation(text, segments: result.segments)

    // Apply text expansions
    text = applyTextExpansions(text)

    // Process voice commands if enabled
    if voiceCommandsEnabled {
      text = processVoiceCommands(text)
    }

    // Final cleanup
    text = TextCleanup.cleanupSpacingAndPunctuation(text)

    AppLogger.transcription.info("PostProcessor: Final output: \"\(text)\"")

    return text
  }

  // MARK: - Noise Filtering

  private func filterNoise(_ text: String) -> String {
    if NoiseFilter.matchesNoisePattern(text) {
      return ""
    }

    var result = text
    result = removeNoiseWords(from: result)
    result = removeBracketedAnnotations(from: result)
    result = removeAsteriskWrappedWords(from: result)
    return result
  }

  private func removeNoiseWords(from text: String) -> String {
    var result = text
    for noiseWord in NoiseFilter.noiseWords {
      let pattern =
        "(?:^|\\s)\\*?\(NSRegularExpression.escapedPattern(for: noiseWord))\\*?[.,!?]*(?:\\s|$)"
      guard let regex = try? NSRegularExpression(
        pattern: pattern,
        options: .caseInsensitive
      ) else { continue }
      result = regex.stringByReplacingMatches(
        in: result,
        range: NSRange(result.startIndex..., in: result),
        withTemplate: " "
      )
    }
    return result
  }

  private func removeBracketedAnnotations(from text: String) -> String {
    var result = text
    let bracketPatterns = ["\\[[^\\]]*\\]", "\\([^)]*\\)"]

    for pattern in bracketPatterns {
      guard let regex = try? NSRegularExpression(
        pattern: pattern,
        options: .caseInsensitive
      ) else { continue }

      let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
      for match in matches.reversed() {
        guard let range = Range(match.range, in: result) else { continue }
        let matchedText = String(result[range])
        if NoiseFilter.isNoiseAnnotation(matchedText) {
          result.replaceSubrange(range, with: "")
        }
      }
    }
    return result
  }

  private func removeAsteriskWrappedWords(from text: String) -> String {
    guard let regex = try? NSRegularExpression(
      pattern: "\\*[^*]+\\*",
      options: .caseInsensitive
    ) else { return text }
    return regex.stringByReplacingMatches(
      in: text,
      range: NSRange(text.startIndex..., in: text),
      withTemplate: ""
    )
  }

  // MARK: - Intelligent Punctuation

  private func applyIntelligentPunctuation(
    _ text: String,
    segments: [TranscriptionSegment]
  ) -> String {
    guard !segments.isEmpty else { return text }

    let processedSegments = analyzeSegments(segments)
    var result = reconstructText(from: processedSegments)

    result = TextCleanup.capitalizeFirst(result)

    if let lastChar = result.last, !".!?".contains(lastChar) {
      result += "."
    }

    return result
  }

  private func analyzeSegments(
    _ segments: [TranscriptionSegment]
  ) -> [(text: String, punctuation: String)] {
    var previousEndTime: TimeInterval = 0
    var processedSegments: [(text: String, punctuation: String)] = []

    for (index, segment) in segments.enumerated() {
      let pauseBeforeSegment = segment.startTime - previousEndTime
      let segmentText = segment.text.trimmingCharacters(in: .whitespaces)
      let punctuation = determinePunctuation(
        pauseBeforeSegment: pauseBeforeSegment,
        segmentText: segmentText,
        segment: segment,
        isFirstSegment: index == 0
      )
      processedSegments.append((segmentText, punctuation))
      previousEndTime = segment.endTime
    }

    return processedSegments
  }

  private func determinePunctuation(
    pauseBeforeSegment: TimeInterval,
    segmentText: String,
    segment: TranscriptionSegment,
    isFirstSegment: Bool
  ) -> String {
    guard !isFirstSegment else { return "" }

    if pauseBeforeSegment > 1.5 {
      return "..."
    } else if pauseBeforeSegment > 0.6 {
      return inferSentenceEndPunctuation(segment)
    } else if pauseBeforeSegment > 0.3 && !segmentText.isEmpty
        && !TextCleanup.isConjunction(segmentText) {
      return ","
    }
    return ""
  }

  private func reconstructText(
    from processedSegments: [(text: String, punctuation: String)]
  ) -> String {
    var result = ""
    for (index, segment) in processedSegments.enumerated() {
      if index > 0 && !segment.punctuation.isEmpty {
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: " "))
        result += segment.punctuation + " "
      } else if index > 0 {
        result += " "
      }

      var segmentText = segment.text
      if index > 0, let lastChar = processedSegments[index - 1].punctuation.last,
        ".!?".contains(lastChar) {
        segmentText = TextCleanup.capitalizeFirst(segmentText)
      }

      result += segmentText
    }
    return result
  }

  private func inferSentenceEndPunctuation(_ segment: TranscriptionSegment) -> String {
    let text = segment.text.lowercased()

    let questionStarters = [
      "what", "where", "when", "why", "who", "how", "which", "whose", "whom",
      "is it", "are you", "do you", "can you", "will you", "would you",
      "could you", "should", "have you", "has", "does", "did"
    ]

    for starter in questionStarters where text.hasPrefix(starter) || text.contains(" \(starter) ") {
      return "?"
    }

    let questionEnders = ["right", "correct", "isn't it", "aren't you", "don't you", "won't you"]
    for ender in questionEnders where text.hasSuffix(ender) {
      return "?"
    }

    return "."
  }

  // MARK: - Text Expansions

  private func applyTextExpansions(_ text: String) -> String {
    var result = TextCleanup.applyExpansions(text, expansions: textExpansions)
    result = TextCleanup.capitalizeI(result)
    return result
  }

  // MARK: - Voice Commands

  private func processVoiceCommands(_ text: String) -> String {
    var result = text

    for command in voiceCommands {
      let pattern = "\\b\(NSRegularExpression.escapedPattern(for: command.phrase))\\b"
      guard let regex = try? NSRegularExpression(
        pattern: pattern,
        options: .caseInsensitive
      ) else { continue }
      result = applyVoiceCommand(command, regex: regex, to: result)
    }

    return result
  }

  private func applyVoiceCommand(
    _ command: VoiceCommand,
    regex: NSRegularExpression,
    to text: String
  ) -> String {
    var result = text
    let range = NSRange(result.startIndex..., in: result)

    switch command.action {
    case .newLine:
      result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "\n")
    case .newParagraph:
      result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "\n\n")
    case .scratchThat:
      result = applyScratchThat(command: command, to: result)
    case .custom(let replacement):
      result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: replacement)
    }

    return result
  }

  private func applyScratchThat(command: VoiceCommand, to text: String) -> String {
    var result = text
    guard let range = result.range(
      of: command.phrase,
      options: [.caseInsensitive, .backwards]
    ) else { return result }

    let beforeCommand = result[..<range.lowerBound]
    if let lastSentenceEnd = beforeCommand.lastIndex(where: { ".!?".contains($0) }) {
      let afterSentence = result.index(after: lastSentenceEnd)
      result.removeSubrange(afterSentence..<range.upperBound)
    } else {
      result.removeSubrange(result.startIndex..<range.upperBound)
    }
    return result
  }
}
