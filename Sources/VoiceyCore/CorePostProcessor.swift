import Foundation

public struct CorePostProcessorConfiguration: Equatable, Sendable {
  public let voiceCommandsEnabled: Bool
  public let voiceCommands: [VoiceCommand]
  public let textExpansions: [String: String]

  public init(
    voiceCommandsEnabled: Bool = false,
    voiceCommands: [VoiceCommand] = [],
    textExpansions: [String: String] = TextCleanup.defaultTextExpansions
  ) {
    self.voiceCommandsEnabled = voiceCommandsEnabled
    self.voiceCommands = voiceCommands
    self.textExpansions = textExpansions
  }
}

public struct CorePostProcessor: Sendable {
  public init() {}

  public func process(
    _ result: CoreTranscriptionResult,
    configuration: CorePostProcessorConfiguration
  ) -> String {
    var text = result.text
    text = filterNoise(text)

    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return ""
    }

    text = applyIntelligentPunctuation(text, segments: result.segments)
    text = applyTextExpansions(text, expansions: configuration.textExpansions)

    if configuration.voiceCommandsEnabled {
      text = processVoiceCommands(text, commands: configuration.voiceCommands.filter { $0.enabled })
    }

    return TextCleanup.cleanupSpacingAndPunctuation(text)
  }

  private func filterNoise(_ text: String) -> String {
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

  private func applyIntelligentPunctuation(
    _ text: String,
    segments: [CoreTranscriptionSegment]
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
    _ segments: [CoreTranscriptionSegment]
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
    segment: CoreTranscriptionSegment,
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

  private func inferSentenceEndPunctuation(_ segment: CoreTranscriptionSegment) -> String {
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

  private func applyTextExpansions(_ text: String, expansions: [String: String]) -> String {
    var result = TextCleanup.applyExpansions(text, expansions: expansions)
    result = TextCleanup.capitalizeI(result)
    return result
  }

  private func processVoiceCommands(_ text: String, commands: [VoiceCommand]) -> String {
    var result = text

    for command in commands {
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
