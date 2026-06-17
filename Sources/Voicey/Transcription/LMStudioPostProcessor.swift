import Foundation
import VoiceyCore

enum LMStudioPostProcessorError: LocalizedError {
  case invalidBaseURL
  case invalidResponse
  case httpError(statusCode: Int)
  case emptyCompletion

  var errorDescription: String? {
    switch self {
    case .invalidBaseURL:
      return "LM Studio base URL is invalid."
    case .invalidResponse:
      return "LM Studio returned an unreadable response."
    case .httpError(let statusCode):
      return "LM Studio request failed with HTTP \(statusCode)."
    case .emptyCompletion:
      return "LM Studio returned an empty completion."
    }
  }
}

/// Applies glossary and screen-context terms via a local OpenAI-compatible LM Studio server.
struct LMStudioPostProcessor: Sendable {
  private let urlSession: URLSession
  private let timeoutInterval: TimeInterval

  init(urlSession: URLSession = .shared, timeoutInterval: TimeInterval = 30) {
    self.urlSession = urlSession
    self.timeoutInterval = timeoutInterval
  }

  func refine(
    transcript: String,
    vocabularyTerms: [String],
    baseURL: String,
    model: String
  ) async throws -> String {
    let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTranscript.isEmpty else {
      return transcript
    }

    let uniqueTerms = dedupeTerms(vocabularyTerms)
    guard !uniqueTerms.isEmpty else {
      return transcript
    }

    let endpoint = try chatCompletionsURL(baseURL: baseURL)
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = timeoutInterval
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let payload = ChatCompletionRequest(
      model: model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : model,
      messages: [
        ChatMessage(
          role: "system",
          content: """
            You correct dictation transcripts using a provided vocabulary list.
            Fix spelling of proper nouns, product names, and technical terms when they clearly \
            match a vocabulary entry. Do not add words, remove content, change meaning, or \
            rewrite style. Return only the corrected transcript with no commentary.
            """
        ),
        ChatMessage(
          role: "user",
          content: """
            Vocabulary: \(uniqueTerms.joined(separator: ", "))

            Transcript:
            \(trimmedTranscript)
            """
        ),
      ],
      temperature: 0,
      stream: false
    )
    request.httpBody = try JSONEncoder().encode(payload)

    let (data, response) = try await urlSession.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw LMStudioPostProcessorError.invalidResponse
    }
    guard (200..<300).contains(httpResponse.statusCode) else {
      throw LMStudioPostProcessorError.httpError(statusCode: httpResponse.statusCode)
    }

    let completion = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
    guard
      let content = completion.choices.first?.message.content?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !content.isEmpty
    else {
      throw LMStudioPostProcessorError.emptyCompletion
    }
    return content
  }

  private func chatCompletionsURL(baseURL: String) throws -> URL {
    var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw LMStudioPostProcessorError.invalidBaseURL
    }
    while trimmed.hasSuffix("/") {
      trimmed.removeLast()
    }
    guard let url = URL(string: trimmed + "/chat/completions") else {
      throw LMStudioPostProcessorError.invalidBaseURL
    }
    return url
  }

  private func dedupeTerms(_ terms: [String]) -> [String] {
    var seen = Set<String>()
    var ordered: [String] = []
    for term in terms {
      let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      let key = trimmed.lowercased()
      guard seen.insert(key).inserted else { continue }
      ordered.append(trimmed)
    }
    return ordered
  }
}

private struct ChatCompletionRequest: Encodable {
  let model: String?
  let messages: [ChatMessage]
  let temperature: Double
  let stream: Bool
}

private struct ChatMessage: Encodable {
  let role: String
  let content: String
}

private struct ChatCompletionResponse: Decodable {
  let choices: [ChatCompletionChoice]
}

private struct ChatCompletionChoice: Decodable {
  let message: ChatCompletionMessage
}

private struct ChatCompletionMessage: Decodable {
  let content: String?
}
