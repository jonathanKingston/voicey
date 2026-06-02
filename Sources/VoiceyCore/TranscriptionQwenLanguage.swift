import Foundation

/// Qwen3-ASR spoken-language hint (`language` parameter). `nil` lets the model auto-detect.
public struct TranscriptionQwenLanguageOption: Sendable, Hashable, Identifiable {
  public let id: String
  /// Value passed to Qwen; `nil` means auto-detect.
  public let qwenLanguageName: String?
  public let displayName: String

  public init(id: String, qwenLanguageName: String?, displayName: String) {
    self.id = id
    self.qwenLanguageName = qwenLanguageName
    self.displayName = displayName
  }
}

public enum TranscriptionQwenLanguage {
  public static let autoOption = TranscriptionQwenLanguageOption(
    id: "auto",
    qwenLanguageName: nil,
    displayName: "Auto-detect"
  )

  /// Languages supported by Qwen3-ASR (full names as used by the Python/MLX APIs).
  public static let supportedOptions: [TranscriptionQwenLanguageOption] = [
    autoOption,
    TranscriptionQwenLanguageOption(id: "chinese", qwenLanguageName: "Chinese", displayName: "Chinese"),
    TranscriptionQwenLanguageOption(id: "english", qwenLanguageName: "English", displayName: "English"),
    TranscriptionQwenLanguageOption(
      id: "cantonese", qwenLanguageName: "Cantonese", displayName: "Cantonese"),
    TranscriptionQwenLanguageOption(id: "arabic", qwenLanguageName: "Arabic", displayName: "Arabic"),
    TranscriptionQwenLanguageOption(id: "german", qwenLanguageName: "German", displayName: "German"),
    TranscriptionQwenLanguageOption(id: "french", qwenLanguageName: "French", displayName: "French"),
    TranscriptionQwenLanguageOption(id: "spanish", qwenLanguageName: "Spanish", displayName: "Spanish"),
    TranscriptionQwenLanguageOption(
      id: "portuguese", qwenLanguageName: "Portuguese", displayName: "Portuguese"),
    TranscriptionQwenLanguageOption(
      id: "indonesian", qwenLanguageName: "Indonesian", displayName: "Indonesian"),
    TranscriptionQwenLanguageOption(id: "italian", qwenLanguageName: "Italian", displayName: "Italian"),
    TranscriptionQwenLanguageOption(id: "korean", qwenLanguageName: "Korean", displayName: "Korean"),
    TranscriptionQwenLanguageOption(id: "russian", qwenLanguageName: "Russian", displayName: "Russian"),
    TranscriptionQwenLanguageOption(id: "thai", qwenLanguageName: "Thai", displayName: "Thai"),
    TranscriptionQwenLanguageOption(
      id: "vietnamese", qwenLanguageName: "Vietnamese", displayName: "Vietnamese"),
    TranscriptionQwenLanguageOption(id: "japanese", qwenLanguageName: "Japanese", displayName: "Japanese"),
    TranscriptionQwenLanguageOption(id: "turkish", qwenLanguageName: "Turkish", displayName: "Turkish"),
    TranscriptionQwenLanguageOption(id: "hindi", qwenLanguageName: "Hindi", displayName: "Hindi"),
    TranscriptionQwenLanguageOption(id: "malay", qwenLanguageName: "Malay", displayName: "Malay"),
    TranscriptionQwenLanguageOption(id: "dutch", qwenLanguageName: "Dutch", displayName: "Dutch"),
    TranscriptionQwenLanguageOption(id: "swedish", qwenLanguageName: "Swedish", displayName: "Swedish"),
    TranscriptionQwenLanguageOption(id: "danish", qwenLanguageName: "Danish", displayName: "Danish"),
    TranscriptionQwenLanguageOption(id: "finnish", qwenLanguageName: "Finnish", displayName: "Finnish"),
    TranscriptionQwenLanguageOption(id: "polish", qwenLanguageName: "Polish", displayName: "Polish"),
    TranscriptionQwenLanguageOption(id: "czech", qwenLanguageName: "Czech", displayName: "Czech"),
    TranscriptionQwenLanguageOption(id: "filipino", qwenLanguageName: "Filipino", displayName: "Filipino"),
    TranscriptionQwenLanguageOption(id: "persian", qwenLanguageName: "Persian", displayName: "Persian"),
    TranscriptionQwenLanguageOption(id: "greek", qwenLanguageName: "Greek", displayName: "Greek"),
    TranscriptionQwenLanguageOption(
      id: "hungarian", qwenLanguageName: "Hungarian", displayName: "Hungarian"),
    TranscriptionQwenLanguageOption(
      id: "macedonian", qwenLanguageName: "Macedonian", displayName: "Macedonian"),
    TranscriptionQwenLanguageOption(
      id: "romanian", qwenLanguageName: "Romanian", displayName: "Romanian")
  ]

  public static func option(id storedID: String) -> TranscriptionQwenLanguageOption? {
    supportedOptions.first { $0.id == storedID }
  }

  public static func qwenLanguageParameter(storedID: String) -> String? {
    let trimmed = storedID.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty || trimmed == autoOption.id {
      return nil
    }
    if let option = option(id: trimmed) {
      return option.qwenLanguageName
    }
    return nil
  }

  public static func normalizedStoredID(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      return autoOption.id
    }
    if option(id: trimmed) != nil {
      return trimmed
    }
    return autoOption.id
  }
}
