import XCTest
@testable import VoiceyCore

final class CorePostProcessorTests: XCTestCase {
  private let processor = CorePostProcessor()

  func testProcessReturnsEmptyForNoiseOnlyResult() {
    let input = CoreTranscriptionResult(text: "[music]")
    let output = processor.process(
      input,
      configuration: CorePostProcessorConfiguration(voiceCommandsEnabled: false)
    )

    XCTAssertEqual(output, "")
  }

  func testProcessAppliesVoiceCommandReplacementWhenEnabled() {
    let input = CoreTranscriptionResult(text: "hello new line world")
    let output = processor.process(
      input,
      configuration: CorePostProcessorConfiguration(
        voiceCommandsEnabled: true,
        voiceCommands: [
          VoiceCommand(phrase: "new line", action: .newLine, enabled: true)
        ]
      )
    )

    XCTAssertEqual(output, "hello \n world")
  }

  func testProcessKeepsVoiceCommandLiteralWhenDisabled() {
    let input = CoreTranscriptionResult(text: "hello new line world")
    let output = processor.process(
      input,
      configuration: CorePostProcessorConfiguration(voiceCommandsEnabled: false)
    )

    XCTAssertEqual(output, "hello new line world")
  }

  func testProcessMarksQuestionFromSegmentHeuristics() {
    let input = CoreTranscriptionResult(
      text: "what time is it",
      segments: [
        CoreTranscriptionSegment(text: "what time is it", startTime: 0, endTime: 1)
      ]
    )
    let output = processor.process(
      input,
      configuration: CorePostProcessorConfiguration(voiceCommandsEnabled: false)
    )

    XCTAssertEqual(output, "What time is it.")
  }
}
