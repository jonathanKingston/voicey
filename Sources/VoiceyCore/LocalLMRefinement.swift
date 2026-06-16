import Foundation

/// Defaults for OpenAI-compatible local servers (LM Studio, Ollama, etc.).
public enum LocalLMRefinementDefaults {
  public static let baseURL = "http://127.0.0.1:1234/v1"
  public static let modelName = "local-model"
  public static let requestTimeoutSeconds: TimeInterval = 30
}

public enum LocalLMRefinementError: Error, Equatable, Sendable {
  case invalidBaseURL
  case emptyModelName
  case emptyTranscript
  case invalidResponse
  case serverError(statusCode: Int)
}

/// Pure helpers for local LM transcript refinement (testable without networking).
public enum LocalLMRefinementPrompt {
  public static let system =
    """
    You correct raw speech-to-text output. Fix spelling and capitalization using the \
    vocabulary list when provided. Do not add, remove, or rephrase content beyond fixing \
    recognition errors. Output only the corrected text with no quotes, labels, or explanation.
    """

  public static func userMessage(
    transcript: String,
    steeringTerms: [String],
    decoderContext: String?
  ) -> String {
    var sections: [String] = []
    if let decoderContext, !decoderContext.isEmpty {
      sections.append(decoderContext)
    } else if !steeringTerms.isEmpty {
      sections.append("Vocabulary: \(steeringTerms.joined(separator: ", "))")
    }
    sections.append("Transcript:\n\(transcript)")
    return sections.joined(separator: "\n\n")
  }
}

public enum LocalLMRefinementURL {
  /// Normalizes a user-provided OpenAI-compatible base URL and validates localhost-only access.
  public static func normalizedChatCompletionsURL(baseURL: String) throws -> URL {
    let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw LocalLMRefinementError.invalidBaseURL }

    var normalized = trimmed
    while normalized.hasSuffix("/") {
      normalized.removeLast()
    }
    if normalized.isEmpty { throw LocalLMRefinementError.invalidBaseURL }

    guard let components = URLComponents(string: normalized),
      let scheme = components.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      let host = components.host?.lowercased(),
      host == "127.0.0.1" || host == "localhost" || host == "::1"
    else {
      throw LocalLMRefinementError.invalidBaseURL
    }

    let chatPath =
      normalized.hasSuffix("/v1")
      ? "\(normalized)/chat/completions" : "\(normalized)/v1/chat/completions"
    guard let url = URL(string: chatPath) else {
      throw LocalLMRefinementError.invalidBaseURL
    }
    return url
  }
}
