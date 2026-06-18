import XCTest
import VoiceyCore

final class InferenceAudioConditioningTests: XCTestCase {
  func testEmptySamplesHaveZeroRMS() {
    XCTAssertEqual(InferenceAudioConditioning.calculateRMS([]), 0)
  }

  func testBelowFloorReturnsEmptySamples() {
    let quiet: [Float] = [0.0001, -0.00005, 0.00008]
    let result = InferenceAudioConditioning.conditionForInference(quiet)
    XCTAssertTrue(result.samples.isEmpty)
    XCTAssertTrue(result.isBelowInferenceFloor)
    XCTAssertEqual(result.appliedGain, 1)
  }

  func testLoudEnoughPassesThroughUnchanged() {
    let samples: [Float] = Array(repeating: 0.05, count: 1_600)
    let result = InferenceAudioConditioning.conditionForInference(samples)
    XCTAssertEqual(result.samples, samples)
    XCTAssertEqual(result.appliedGain, 1)
  }

  func testQuietSpeechReceivesBoundedGain() {
    let rms: Float = 0.006
    let scale = rms / 0.5
    let samples = (0..<1_600).map { _ in Float.random(in: -scale...scale) }
    let measured = InferenceAudioConditioning.calculateRMS(samples)
    XCTAssertLessThan(measured, InferenceAudioConditioning.lowAudioBoostThresholdRMS)

    let result = InferenceAudioConditioning.conditionForInference(samples)
    XCTAssertGreaterThan(result.appliedGain, 1)
    XCTAssertLessThanOrEqual(result.appliedGain, InferenceAudioConditioning.maxInputGain)
    XCTAssertFalse(result.samples.isEmpty)
    let outRMS = InferenceAudioConditioning.calculateRMS(result.samples)
    XCTAssertGreaterThan(outRMS, measured)
  }
}
