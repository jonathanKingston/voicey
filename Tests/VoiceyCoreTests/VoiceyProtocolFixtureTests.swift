import XCTest

@testable import VoiceyCore

/// Decodes shared golden JSON from `crates/voicey-protocol/fixtures/`.
final class VoiceyProtocolFixtureTests: XCTestCase {
  private let decoder = JSONDecoder()
  private let encoder = JSONEncoder()

  /// Repo root: `Tests/VoiceyCoreTests` → `Tests` → workspace root.
  private var fixturesRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("crates/voicey-protocol/fixtures", isDirectory: true)
  }

  func testProtocolVersionMatchesRust() {
    XCTAssertEqual(VoiceyProtocol.version, 1)
  }

  func testHostRequestFixturesDecodeAndRoundtrip() throws {
    try assertFixtureRoundtrip(
      subdirectory: "host_request",
      decode: VoiceyHostRequest.self
    )
  }

  func testHostResponseFixturesDecodeAndRoundtrip() throws {
    try assertFixtureRoundtrip(
      subdirectory: "host_response",
      decode: VoiceyHostResponse.self
    )
  }

  func testInferWorkerRequestFixturesDecodeAndRoundtrip() throws {
    try assertFixtureRoundtrip(
      subdirectory: "infer_worker_request",
      decode: VoiceyInferWorkerRequest.self
    )
  }

  func testInferWorkerResponseFixturesDecodeAndRoundtrip() throws {
    try assertFixtureRoundtrip(
      subdirectory: "infer_worker_response",
      decode: VoiceyInferWorkerResponse.self
    )
  }

  func testRuntimeKindFixturesDecodeAndRoundtrip() throws {
    try assertFixtureRoundtrip(
      subdirectory: "runtime_kind",
      decode: VoiceyRuntimeKind.self
    )
  }

  func testRejectFixturesFailToDecodeHostRequest() throws {
    let url =
      fixturesRoot
      .appendingPathComponent("reject/host_request_unknown_type.json")
    let data = try Data(contentsOf: url)
    XCTAssertThrowsError(try decoder.decode(VoiceyHostRequest.self, from: data))
  }

  private func assertFixtureRoundtrip<T: Codable & Equatable>(
    subdirectory: String,
    decode: T.Type
  ) throws {
    for url in try fixtureURLs(subdirectory: subdirectory) {
      let data = try Data(contentsOf: url)
      let value = try decoder.decode(T.self, from: data)
      let roundtripData = try encoder.encode(value)
      let roundtrip = try decoder.decode(T.self, from: roundtripData)
      XCTAssertEqual(value, roundtrip, "roundtrip mismatch for \(url.lastPathComponent)")
    }
  }

  private func fixtureURLs(subdirectory: String) throws -> [URL] {
    let base = fixturesRoot.appendingPathComponent(subdirectory, isDirectory: true)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: base.path, isDirectory: &isDirectory), isDirectory.boolValue
    else {
      XCTFail(
        "Missing protocol fixtures at \(base.path). Run: make protocol-fixtures"
      )
      return []
    }
    let urls = try FileManager.default.contentsOfDirectory(
      at: base,
      includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "json" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

    XCTAssertFalse(urls.isEmpty, "no fixtures in \(subdirectory)")
    return urls
  }

}
