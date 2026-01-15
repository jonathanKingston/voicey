import Foundation

/// Post-processes transcription output for punctuation, formatting, and voice commands
final class PostProcessor {
    private let textExpansions: [String: String]
    
    init() {
        self.textExpansions = Self.defaultTextExpansions
    }
    
    /// Get current voice commands settings (read fresh each time)
    private var voiceCommandsEnabled: Bool {
        SettingsManager.shared.voiceCommandsEnabled
    }
    
    private var voiceCommands: [VoiceCommand] {
        SettingsManager.shared.voiceCommands.filter { $0.enabled }
    }
    
    // MARK: - Default Text Expansions
    
    private static let defaultTextExpansions: [String: String] = [
        "etcetera": "etc.",
        "et cetera": "etc.",
        "for example": "e.g.",
        "that is": "i.e.",
        "versus": "vs.",
        "mister": "Mr.",
        "missus": "Mrs.",
        "doctor": "Dr.",
        "okay": "OK",
        "o k": "OK"
    ]
    
    // MARK: - Processing
    
    func process(_ result: TranscriptionResult) -> String {
        var text = result.text
        
        // Apply intelligent punctuation based on timing and segment analysis
        text = applyIntelligentPunctuation(text, segments: result.segments)
        
        // Apply text expansions
        text = applyTextExpansions(text)
        
        // Process voice commands if enabled
        if voiceCommandsEnabled {
            text = processVoiceCommands(text)
        }
        
        // Final cleanup
        text = finalCleanup(text)
        
        return text
    }
    
    // MARK: - Intelligent Punctuation
    
    private func applyIntelligentPunctuation(_ text: String, segments: [TranscriptionSegment]) -> String {
        guard !segments.isEmpty else { return text }
        
        var result = text
        
        // Analyze segment timing for pause-based punctuation
        var previousEndTime: TimeInterval = 0
        var processedSegments: [(text: String, punctuation: String)] = []
        
        for (index, segment) in segments.enumerated() {
            let pauseBeforeSegment = segment.startTime - previousEndTime
            let segmentText = segment.text.trimmingCharacters(in: .whitespaces)
            var punctuation = ""
            
            // Determine punctuation based on pause duration
            if index > 0 {
                if pauseBeforeSegment > 1.5 {
                    // Long pause - paragraph break or ellipsis
                    punctuation = "..."
                } else if pauseBeforeSegment > 0.6 {
                    // Medium pause - sentence ending
                    punctuation = inferSentenceEndPunctuation(segment)
                } else if pauseBeforeSegment > 0.3 {
                    // Short pause - comma
                    if !segmentText.isEmpty && !isConjunction(segmentText) {
                        punctuation = ","
                    }
                }
            }
            
            processedSegments.append((segmentText, punctuation))
            previousEndTime = segment.endTime
        }
        
        // Reconstruct text with punctuation
        result = ""
        for (index, segment) in processedSegments.enumerated() {
            if index > 0 && !segment.punctuation.isEmpty {
                // Remove trailing space before adding punctuation
                result = result.trimmingCharacters(in: CharacterSet(charactersIn: " "))
                result += segment.punctuation + " "
            } else if index > 0 {
                result += " "
            }
            
            // Capitalize after sentence-ending punctuation
            var segmentText = segment.text
            if index > 0, let lastChar = processedSegments[index - 1].punctuation.last,
               ".!?".contains(lastChar) {
                segmentText = capitalizeFirst(segmentText)
            }
            
            result += segmentText
        }
        
        // Ensure first letter is capitalized
        result = capitalizeFirst(result)
        
        // Add final punctuation if missing
        if let lastChar = result.last, !".!?".contains(lastChar) {
            result += "."
        }
        
        return result
    }
    
    private func inferSentenceEndPunctuation(_ segment: TranscriptionSegment) -> String {
        // Analyze token probabilities and patterns for question detection
        let text = segment.text.lowercased()
        
        // Question word patterns
        let questionStarters = ["what", "where", "when", "why", "who", "how", "which", "whose", "whom",
                               "is it", "are you", "do you", "can you", "will you", "would you",
                               "could you", "should", "have you", "has", "does", "did"]
        
        for starter in questionStarters {
            if text.hasPrefix(starter) || text.contains(" \(starter) ") {
                return "?"
            }
        }
        
        // Question ending patterns
        let questionEnders = ["right", "correct", "isn't it", "aren't you", "don't you", "won't you"]
        for ender in questionEnders {
            if text.hasSuffix(ender) {
                return "?"
            }
        }
        
        // Default to period
        return "."
    }
    
    private func isConjunction(_ text: String) -> Bool {
        let conjunctions = ["and", "but", "or", "so", "yet", "for", "nor", "because", "although", "while", "if", "when"]
        let firstWord = text.lowercased().split(separator: " ").first.map(String.init) ?? ""
        return conjunctions.contains(firstWord)
    }
    
    private func capitalizeFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
    
    // MARK: - Text Expansions
    
    private func applyTextExpansions(_ text: String) -> String {
        var result = text
        
        for (spoken, written) in textExpansions {
            // Case-insensitive replacement
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: spoken))\\b"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: written
                )
            }
        }
        
        // Always capitalize "I"
        result = result.replacingOccurrences(of: " i ", with: " I ")
        result = result.replacingOccurrences(of: " i'", with: " I'")
        if result.hasPrefix("i ") {
            result = "I" + result.dropFirst()
        }
        
        return result
    }
    
    // MARK: - Voice Commands
    
    private func processVoiceCommands(_ text: String) -> String {
        var result = text
        
        for command in voiceCommands {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: command.phrase))\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            
            switch command.action {
            case .newLine:
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: "\n"
                )
            case .newParagraph:
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: "\n\n"
                )
            case .scratchThat:
                // Find and remove the last segment before this command
                if let range = result.range(of: command.phrase, options: [.caseInsensitive, .backwards]) {
                    // Remove from the previous sentence end to this command
                    let beforeCommand = result[..<range.lowerBound]
                    if let lastSentenceEnd = beforeCommand.lastIndex(where: { ".!?".contains($0) }) {
                        let afterSentence = result.index(after: lastSentenceEnd)
                        result.removeSubrange(afterSentence..<range.upperBound)
                    } else {
                        // Remove everything before the command
                        result.removeSubrange(result.startIndex..<range.upperBound)
                    }
                }
            case .custom(let replacement):
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: replacement
                )
            }
        }
        
        return result
    }
    
    // MARK: - Final Cleanup
    
    private func finalCleanup(_ text: String) -> String {
        var result = text
        
        // Fix multiple spaces
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        
        // Fix space before punctuation
        result = result.replacingOccurrences(of: " .", with: ".")
        result = result.replacingOccurrences(of: " ,", with: ",")
        result = result.replacingOccurrences(of: " ?", with: "?")
        result = result.replacingOccurrences(of: " !", with: "!")
        
        // Fix multiple punctuation
        result = result.replacingOccurrences(of: "..", with: ".")
        result = result.replacingOccurrences(of: ",,", with: ",")
        result = result.replacingOccurrences(of: "....", with: "...")
        
        // Ensure space after punctuation
        let punctuationPattern = "([.!?,])([A-Za-z])"
        if let regex = try? NSRegularExpression(pattern: punctuationPattern) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1 $2"
            )
        }
        
        // Trim
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        
        return result
    }
}

// MARK: - Voice Command Types

enum VoiceCommandAction: Codable, Equatable {
    case newLine
    case newParagraph
    case scratchThat
    case custom(String)
}

struct VoiceCommand: Identifiable, Codable {
    let id: UUID
    var phrase: String
    var action: VoiceCommandAction
    var enabled: Bool
    
    static let defaults: [VoiceCommand] = [
        VoiceCommand(id: UUID(), phrase: "new line", action: .newLine, enabled: true),
        VoiceCommand(id: UUID(), phrase: "new paragraph", action: .newParagraph, enabled: true),
        VoiceCommand(id: UUID(), phrase: "scratch that", action: .scratchThat, enabled: true)
    ]
}
