import Foundation
import Testing
@testable import Voicey

@Suite struct LMStudioPostProcessorTests {
  @Test func refineReturnsBaselineWhenVocabularyIsEmpty() async throws {
    let processor = LMStudioPostProcessor()
    let result = try await processor.refine(
      transcript: "hello world",
      vocabularyTerms: [],
      baseURL: "http://127.0.0.1:1234/v1",
      model: ""
    )
    #expect(result == "hello world")
  }

  @Test func refineUsesOpenAICompatibleEndpoint() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    let session = URLSession(configuration: config)

    MockURLProtocol.requestHandler = { request in
      #expect(request.url?.absoluteString == "http://127.0.0.1:1234/v1/chat/completions")
      #expect(request.httpMethod == "POST")

      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      let payload = """
        {"choices":[{"message":{"content":"Voicey rocks."}}]}
        """
      return (response, Data(payload.utf8))
    }

    let processor = LMStudioPostProcessor(urlSession: session)
    let result = try await processor.refine(
      transcript: "voicey rocks",
      vocabularyTerms: ["Voicey", "WhisperKit"],
      baseURL: "http://127.0.0.1:1234/v1",
      model: "local-model"
    )
    #expect(result == "Voicey rocks.")
  }
}

private final class MockURLProtocol: URLProtocol {
  nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let handler = Self.requestHandler else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    do {
      let (response, data) = try handler(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}
