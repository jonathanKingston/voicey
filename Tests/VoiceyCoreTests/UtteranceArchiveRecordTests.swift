import XCTest

@testable import VoiceyCore

final class UtteranceArchiveRecordTests: XCTestCase {
  func testJSONRoundTrip() throws {
    let created = Date(timeIntervalSince1970: 1_700_000_000)
    let record = UtteranceArchiveRecord(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
      createdAt: created,
      outcome: .emptyDelivery,
      errorMessage: nil,
      modelID: "qwen3-asr-1.7b-bf16",
      languageID: "en",
      audioSeconds: 2.5,
      audioPath: "audio/00000000-0000-0000-0000-000000000001.wav",
      rawText: "hello",
      processedText: "",
      steeringTerms: ["Acme"],
      decoderContextSHA256: "abc",
      glossaryEnabled: true,
      screenContextEnabled: false,
      snapshotPath: nil,
      targetAppBundleID: "com.example.app",
      voiceyVersion: "1.0",
      runtime: "multiprocess"
    )

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(record)
    let json = try XCTUnwrap(String(data: data, encoding: .utf8))
    XCTAssertTrue(json.contains("\"empty_delivery\""))
    XCTAssertTrue(json.contains("\"model_id\""))

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(UtteranceArchiveRecord.self, from: data)
    XCTAssertEqual(decoded, record)
  }

  func testRetentionEvictsOldest() {
    let base = Date(timeIntervalSince1970: 0)
    let records = (0..<3).map { index in
      UtteranceArchiveRecord(
        createdAt: base.addingTimeInterval(TimeInterval(index)),
        outcome: .completed,
        modelID: "m",
        languageID: "auto",
        audioSeconds: 1,
        audioPath: "audio/\(index).wav",
        rawText: "",
        processedText: "x",
        steeringTerms: [],
        glossaryEnabled: false,
        screenContextEnabled: false
      )
    }
    let evicted = SessionArchiveRetentionPolicy.recordIDsToEvict(records: records, maxEntries: 2)
    XCTAssertEqual(evicted.count, 1)
    XCTAssertEqual(evicted.first, records[0].id)
  }
}
