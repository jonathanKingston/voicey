import Foundation
import VoiceyCore
import os

/// Refines raw ASR output via a localhost OpenAI-compatible chat API (LM Studio, Ollama, etc.).
enum LocalLMTextRefiner {
  static func refine(
    transcript: String,
    steeringTerms: [String],
    decoderContext: String?,
    settings: SettingsProviding = SettingsManager.shared,
    session: URLSession = .shared
  ) async throws -> String {
    guard settings.localLMRefinementEnabled else {
      return transcript
    }

    let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTranscript.isEmpty else {
      throw LocalLMRefinementError.emptyTranscript
    }

    let modelName = settings.localLMModelName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !modelName.isEmpty else {
      throw LocalLMRefinementError.emptyModelName
    }

    let endpoint = try LocalLMRefinementURL.normalizedChatCompletionsURL(
      baseURL: settings.localLMBaseURL
    )
    let userMessage = LocalLMRefinementPrompt.userMessage(
      transcript: trimmedTranscript,
      steeringTerms: steeringTerms,
      decoderContext: decoderContext
    )

    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = LocalLMRefinementDefaults.requestTimeoutSeconds
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(
      ChatCompletionRequest(
        model: modelName,
        messages: [
          ChatCompletionRequest.Message(role: "system", content: LocalLMRefinementPrompt.system),
          ChatCompletionRequest.Message(role: "user", content: userMessage)
        ],
        temperature: 0
      )
    )

    AppLogger.transcription.info(
      "LocalLM: refining transcript chars=\(trimmedTranscript.count) steeringTerms=\(steeringTerms.count)"
    )

    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw LocalLMRefinementError.invalidResponse
    }
    guard (200..<300).contains(httpResponse.statusCode) else {
      AppLogger.transcription.error(
        "LocalLM: server returned HTTP \(httpResponse.statusCode, privacy: .public)"
      )
      throw LocalLMRefinementError.serverError(statusCode: httpResponse.statusCode)
    }

    let completion = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
    guard
      let content = completion.choices.first?.message.content?.trimmingCharacters(
        in: .whitespacesAndNewlines
      ), !content.isEmpty
    else {
      throw LocalLMRefinementError.invalidResponse
    }

    AppLogger.transcription.info("LocalLM: refined transcript chars=\(content.count)")
    return content
  }
}

private struct ChatCompletionRequest: Encodable {
  struct Message: Encodable {
    let role: String
    let content: String
  }

  let model: String
  let messages: [Message]
  let temperature: Double
}

private struct ChatCompletionResponseChoiceMessage: Decodable {
  let content: String?
}

private struct ChatCompletionResponseChoice: Decodable {
  let message: ChatCompletionResponseChoiceMessage
}

private struct ChatCompletionResponse: Decodable {
  let choices: [ChatCompletionResponseChoice]
}

extension LocalLMRefinementError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .invalidBaseURL:
      return
        "Local language model base URL must be a localhost OpenAI-compatible endpoint (for example http://127.0.0.1:1234/v1)."
    case .emptyModelName:
      return "Local language model name is required."
    case .emptyTranscript:
      return "Nothing to refine: transcription was empty."
    case .invalidResponse:
      return "Local language model returned an invalid response."
    case .serverError(let statusCode):
      return "Local language model request failed (HTTP \(statusCode))."
    }
  }
}
