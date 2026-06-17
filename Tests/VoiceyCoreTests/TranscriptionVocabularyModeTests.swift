import Foundation
import Testing
@testable import VoiceyCore

@Suite struct TranscriptionVocabularyModeTests {
  @Test func rawValuesRoundTrip() {
    for mode in TranscriptionVocabularyMode.allCases {
      #expect(TranscriptionVocabularyMode(rawValue: mode.rawValue) == mode)
    }
  }

  @Test func unknownRawValueFallsBackToDecoderSteering() {
    #expect(TranscriptionVocabularyMode(rawValue: "unknown") == nil)
  }
}
