import Foundation

/// Segment timing for intelligent punctuation (Whisper / benchmark backends).
public struct PostProcessSegment: Sendable, Equatable {
  public let text: String
  public let startTime: Double
  public let endTime: Double

  public init(text: String, startTime: Double, endTime: Double) {
    self.text = text
    self.startTime = startTime
    self.endTime = endTime
  }
}

/// Post-processes transcription output for expansions, voice commands, and formatting.
/// Mirrors `voicey-text` `postprocess` for Linux CI golden fixture parity.
public enum PostProcessBuilder {
  public struct Input: Sendable {
    public let text: String
    public let segments: [PostProcessSegment]
    public let voiceCommandsEnabled: Bool
    public let voiceCommands: [VoiceCommand]

    public init(
      text: String,
      segments: [PostProcessSegment],
      voiceCommandsEnabled: Bool,
      voiceCommands: [VoiceCommand]
    ) {
      self.text = text
      self.segments = segments
      self.voiceCommandsEnabled = voiceCommandsEnabled
      self.voiceCommands = voiceCommands
    }
  }

  public static func build(_ input: Input) -> String {
    let textExpansions = TextCleanup.defaultTextExpansions
    var text = input.text

    if !input.segments.isEmpty {
      text = filterNoise(text)
      if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return ""
      }
    }

    text = applyIntelligentPunctuation(text, segments: input.segments)
    text = applyTextExpansions(text, expansions: textExpansions)

    if input.voiceCommandsEnabled {
      let enabled = input.voiceCommands.filter(\.enabled)
      text = processVoiceCommands(text, voiceCommands: enabled)
    }

    return TextCleanup.cleanupSpacingAndPunctuation(text)
  }

  private static func filterNoise(_ text: String) -> String {
    if NoiseFilter.matchesNoisePattern(text) {
      return ""
    }

    var result = text
    result = removeNoiseWords(from: result)
    result = removeBracketedAnnotations(from: result)
    result = removeAsteriskWrappedWords(from: result)
    result = NoiseFilter.removeTrailingRepeatedArtifacts(result)
    return result
  }

  private static func removeNoiseWords(from text: String) -> String {
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

  private static func removeBracketedAnnotations(from text: String) -> String {
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

  private static func removeAsteriskWrappedWords(from text: String) -> String {
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

  private static func applyIntelligentPunctuation(
    _ text: String,
    segments: [PostProcessSegment]
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

  private static func analyzeSegments(
    _ segments: [PostProcessSegment]
  ) -> [(text: String, punctuation: String)] {
    var previousEndTime = 0.0
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

  private static func determinePunctuation(
    pauseBeforeSegment: Double,
    segmentText: String,
    segment: PostProcessSegment,
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

  private static func reconstructText(
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

  private static func inferSentenceEndPunctuation(_ segment: PostProcessSegment) -> String {
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

  private static func applyTextExpansions(_ text: String, expansions: [String: String]) -> String {
    var result = TextCleanup.applyExpansions(text, expansions: expansions)
    result = TextCleanup.capitalizeI(result)
    return result
  }

  private static func processVoiceCommands(_ text: String, voiceCommands: [VoiceCommand]) -> String {
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

  private static func applyVoiceCommand(
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

  private static func applyScratchThat(command: VoiceCommand, to text: String) -> String {
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
