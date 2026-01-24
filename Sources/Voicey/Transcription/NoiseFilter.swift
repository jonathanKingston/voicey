import Foundation

/// Constants and logic for filtering noise words from transcription output
enum NoiseFilter {
  /// Words/phrases that Whisper often outputs for non-speech sounds
  /// These should be filtered out as they're typically noise artifacts
  static let noiseWords: Set<String> = [
    // Onomatopoeia for sounds
    "bang", "click", "clicks", "clicking", "clack", "clunk",
    "beep", "beeps", "beeping", "boop",
    "thud", "thump", "thumping",
    "tap", "taps", "tapping",
    "knock", "knocks", "knocking",
    "buzz", "buzzing", "hum", "humming",
    "ring", "rings", "ringing", "ding", "dong",
    "pop", "pops", "popping",
    "crack", "crackle", "crackling",
    "snap", "snaps", "snapping",
    "whoosh", "swoosh", "swish",
    "rustle", "rustling",
    "scratch", "scratching",
    "squeak", "squeaking", "creak", "creaking",
    "slam", "slamming",
    "crash", "crashing",
    "bang", "banging",
    "clatter", "clattering",
    "rattle", "rattling",
    "shuffle", "shuffling",
    "footsteps", "footstep",

    // Breathing/vocal sounds
    "sigh", "sighs", "sighing",
    "cough", "coughs", "coughing",
    "sneeze", "sneezes", "sneezing",
    "sniff", "sniffs", "sniffling",
    "gasp", "gasps", "gasping",
    "yawn", "yawns", "yawning",
    "grunt", "grunts", "grunting",
    "groan", "groans", "groaning",
    "moan", "moans", "moaning",
    "huff", "huffs", "huffing",
    "puff", "puffs", "puffing",
    "wheeze", "wheezes", "wheezing",
    "inhale", "inhales", "exhale", "exhales",
    "breath", "breathing",

    // Music/ambient descriptions
    "music", "music playing", "playing music",
    "silence", "static", "noise",
    "applause", "clapping", "cheering",
    "laughter", "laughing", "chuckling",

    // Whisper artifacts for silence
    "...", "…",
    "[silence]", "[music]", "[noise]", "[applause]",
    "(silence)", "(music)", "(noise)", "(applause)",
    "*silence*", "*music*", "*noise*",
    "[inaudible]", "(inaudible)", "*inaudible*",
    "[unintelligible]", "(unintelligible)",
    "[background noise]", "(background noise)",
    "[typing]", "(typing)", "typing",
    "[keyboard]", "(keyboard)", "keyboard sounds"
  ]

  /// Patterns that indicate noise (regex patterns)
  static let noisePatterns: [String] = [
    "^\\s*\\*[^*]+\\*\\s*$",  // *anything in asterisks*
    "^\\s*\\[[^\\]]+\\]\\s*$",  // [anything in brackets]
    "^\\s*\\([^)]+\\)\\s*$",  // (anything in parentheses) when it's the whole text
    "^\\s*\\.+\\s*$",  // Just dots/ellipsis
    "^\\s*…+\\s*$"  // Just ellipsis character
  ]

  /// Keywords that indicate a bracketed annotation is noise
  static let noiseAnnotationKeywords = [
    "music", "noise", "silence", "inaudible", "typing", "applause"
  ]

  /// Check if a bracketed text looks like a noise annotation
  static func isNoiseAnnotation(_ text: String) -> Bool {
    let lowercased = text.lowercased()
    return noiseWords.contains { lowercased.contains($0) }
      || noiseAnnotationKeywords.contains { lowercased.contains($0) }
  }

  /// Check if entire text matches a noise pattern
  static func matchesNoisePattern(_ text: String) -> Bool {
    for pattern in noisePatterns {
      guard let regex = try? NSRegularExpression(
        pattern: pattern,
        options: .caseInsensitive
      ) else { continue }
      let range = NSRange(text.startIndex..., in: text)
      if regex.firstMatch(in: text, range: range) != nil {
        return true
      }
    }
    return false
  }
}
