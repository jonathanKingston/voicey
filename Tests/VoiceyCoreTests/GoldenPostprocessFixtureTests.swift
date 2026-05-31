import XCTest

@testable import VoiceyCore

/// Decodes shared golden JSON from `Benchmarks/Golden/postprocess/`.
/// Parity guard for `cargo test -p voicey-text --test golden_postprocess`.
final class GoldenPostprocessFixtureTests: XCTestCase {
  private let decoder = JSONDecoder()

  private var fixturesRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Benchmarks/Golden/postprocess", isDirectory: true)
  }

  func testGoldenPostprocessFixturesMatchExpected() throws {
    for url in try fixtureURLs() {
      let name = url.lastPathComponent
      let data = try Data(contentsOf: url)
      let fixture = try decoder.decode(GoldenFixture.self, from: data)

      let segments = fixture.segments.map {
        PostProcessSegment(text: $0.text, startTime: $0.startTime, endTime: $0.endTime)
      }
      let voiceCommands = try fixture.voiceCommands.map { try $0.toVoiceCommand() }

      let actual = PostProcessBuilder.build(
        PostProcessBuilder.Input(
          text: fixture.text,
          segments: segments,
          voiceCommandsEnabled: fixture.voiceCommandsEnabled,
          voiceCommands: voiceCommands
        )
      )

      XCTAssertEqual(
        actual,
        fixture.expected,
        "\(name) (\(fixture.description)): postprocess mismatch"
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
        "Missing golden fixtures at \(fixturesRoot.path). Commit Benchmarks/Golden/postprocess/."
      )
      return []
    }

    let urls = try FileManager.default.contentsOfDirectory(
      at: fixturesRoot,
      includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "json" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

    XCTAssertFalse(urls.isEmpty, "no JSON fixtures in postprocess/")
    return urls
  }
}

private struct WireSegment: Decodable {
  let text: String
  let startTime: Double
  let endTime: Double

  enum CodingKeys: String, CodingKey {
    case text
    case startTime = "start_time"
    case endTime = "end_time"
  }
}

private struct WireVoiceCommand: Decodable {
  let phrase: String
  let action: String
  let enabled: Bool

  func toVoiceCommand() throws -> VoiceCommand {
    let commandAction: VoiceCommandAction
    switch action {
    case "new_line":
      commandAction = .newLine
    case "new_paragraph":
      commandAction = .newParagraph
    case "scratch_that":
      commandAction = .scratchThat
    case "custom":
      throw DecodingError.dataCorrupted(
        .init(codingPath: [], debugDescription: "custom action requires replacement in fixture")
      )
    default:
      if action.hasPrefix("custom:") {
        let replacement = String(action.dropFirst("custom:".count))
        commandAction = .custom(replacement)
      } else {
        throw DecodingError.dataCorrupted(
          .init(codingPath: [], debugDescription: "unknown voice command action: \(action)")
        )
      }
    }
    return VoiceCommand(id: UUID(), phrase: phrase, action: commandAction, enabled: enabled)
  }
}

private struct GoldenFixture: Decodable {
  let description: String
  let text: String
  let segments: [WireSegment]
  let voiceCommandsEnabled: Bool
  let voiceCommands: [WireVoiceCommand]
  let expected: String

  enum CodingKeys: String, CodingKey {
    case description
    case text
    case segments
    case voiceCommandsEnabled = "voice_commands_enabled"
    case voiceCommands = "voice_commands"
    case expected
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    description = try container.decode(String.self, forKey: .description)
    text = try container.decode(String.self, forKey: .text)
    segments = try container.decodeIfPresent([WireSegment].self, forKey: .segments) ?? []
    voiceCommandsEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .voiceCommandsEnabled) ?? false
    voiceCommands =
      try container.decodeIfPresent([WireVoiceCommand].self, forKey: .voiceCommands) ?? []
    expected = try container.decode(String.self, forKey: .expected)
  }
}
