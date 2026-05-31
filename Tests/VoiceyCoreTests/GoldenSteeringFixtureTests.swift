import XCTest

@testable import VoiceyCore

/// Decodes shared golden JSON from `Benchmarks/Golden/steering/`.
/// Parity guard for `cargo test -p voicey-text --test golden_steering`.
final class GoldenSteeringFixtureTests: XCTestCase {
  private let decoder = JSONDecoder()

  /// Repo root: `Tests/VoiceyCoreTests` → `Tests` → workspace root.
  private var fixturesRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Benchmarks/Golden/steering", isDirectory: true)
  }

  func testGoldenSteeringFixturesMatchExpected() throws {
    for url in try fixtureURLs() {
      let name = url.lastPathComponent
      let data = try Data(contentsOf: url)
      let fixture = try decoder.decode(GoldenFixture.self, from: data)

      let snapshot = fixture.snapshot.map {
        ScreenContextSnapshot(queryText: $0.queryText, corpusChunks: $0.corpusChunks)
      }
      let maxTerms = fixture.maxTerms ?? ScreenTermSelector.defaultMaxTerms

      let actual = SteeringContextBuilder.build(
        SteeringContextBuilder.Input(
          manualGlossaryEnabled: fixture.manualGlossaryEnabled,
          manualGlossary: fixture.manualGlossary,
          screenContextEnabled: fixture.screenContextEnabled,
          snapshot: snapshot,
          maxTerms: maxTerms
        )
      )

      XCTAssertEqual(
        actual.terms,
        fixture.expectedTerms,
        "\(name) (\(fixture.description)): terms mismatch"
      )
      XCTAssertEqual(
        actual.decoderContext,
        fixture.expectedDecoderContext,
        "\(name) (\(fixture.description)): decoder_context mismatch"
      )
    }
  }

  private func fixtureURLs() throws -> [URL] {
    var isDirectory: ObjCBool = false
    guard
      FileManager.default.fileExists(atPath: fixturesRoot.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      XCTFail(
        "Missing golden fixtures at \(fixturesRoot.path). Commit Benchmarks/Golden/steering/."
      )
      return []
    }

    let urls = try FileManager.default.contentsOfDirectory(
      at: fixturesRoot,
      includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "json" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

    XCTAssertFalse(urls.isEmpty, "no JSON fixtures in steering/")
    return urls
  }
}

private struct WireSnapshot: Decodable {
  let queryText: String
  let corpusChunks: [String]

  enum CodingKeys: String, CodingKey {
    case queryText = "query_text"
    case corpusChunks = "corpus_chunks"
  }
}

private struct GoldenFixture: Decodable {
  let description: String
  let manualGlossaryEnabled: Bool
  let manualGlossary: String
  let screenContextEnabled: Bool
  let snapshot: WireSnapshot?
  let maxTerms: Int?
  let expectedTerms: [String]
  let expectedDecoderContext: String?

  enum CodingKeys: String, CodingKey {
    case description
    case manualGlossaryEnabled = "manual_glossary_enabled"
    case manualGlossary = "manual_glossary"
    case screenContextEnabled = "screen_context_enabled"
    case snapshot
    case maxTerms = "max_terms"
    case expectedTerms = "expected_terms"
    case expectedDecoderContext = "expected_decoder_context"
  }
}
