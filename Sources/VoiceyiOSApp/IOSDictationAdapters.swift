import AVFoundation
import Foundation
import VoiceyCore

enum IOSAudioCapturerError: LocalizedError {
  case invalidOutputFormat

  var errorDescription: String? {
    switch self {
    case .invalidOutputFormat:
      return "Unable to configure iOS audio capture output format."
    }
  }
}

final class IOSAudioCapturer: @unchecked Sendable, AudioCapturing {
  private let targetSampleRate: Double = 16_000
  private let sampleLock = NSLock()

  private var audioEngine: AVAudioEngine?
  private var inputNode: AVAudioInputNode?
  private var converter: AVAudioConverter?
  private var capturedSamples: [Float] = []

  func start() throws {
    capturedSamples.removeAll()

    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
    try session.setActive(true, options: .notifyOthersOnDeactivation)

    let engine = AVAudioEngine()
    let input = engine.inputNode
    let inputFormat = input.outputFormat(forBus: 0)

    guard
      let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: targetSampleRate,
        channels: 1,
        interleaved: false
      )
    else {
      throw IOSAudioCapturerError.invalidOutputFormat
    }

    if inputFormat.sampleRate != targetSampleRate || inputFormat.channelCount != 1 {
      converter = AVAudioConverter(from: inputFormat, to: outputFormat)
    } else {
      converter = nil
    }

    input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
      self?.appendSamples(from: buffer)
    }

    engine.prepare()
    try engine.start()

    audioEngine = engine
    inputNode = input
  }

  func stop() throws -> [Float] {
    inputNode?.removeTap(onBus: 0)
    audioEngine?.stop()
    audioEngine = nil
    inputNode = nil
    converter = nil
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

    sampleLock.lock()
    defer { sampleLock.unlock() }
    let samples = capturedSamples
    capturedSamples = []
    return samples
  }

  private func appendSamples(from buffer: AVAudioPCMBuffer) {
    let samples: [Float]
    if converter != nil || buffer.format.channelCount > 1 || buffer.format.sampleRate != targetSampleRate {
      samples = convertBuffer(buffer)
    } else if let channelData = buffer.floatChannelData {
      samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
    } else {
      samples = []
    }

    sampleLock.lock()
    capturedSamples.append(contentsOf: samples)
    sampleLock.unlock()
  }

  private func convertBuffer(_ buffer: AVAudioPCMBuffer) -> [Float] {
    guard let converter else {
      return averageChannels(buffer)
    }

    let ratio = converter.outputFormat.sampleRate / buffer.format.sampleRate
    let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
    guard
      let outputBuffer = AVAudioPCMBuffer(
        pcmFormat: converter.outputFormat,
        frameCapacity: outputFrameCount
      )
    else {
      return averageChannels(buffer)
    }

    var conversionError: NSError?
    let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
      outStatus.pointee = .haveData
      return buffer
    }

    guard status != .error, conversionError == nil, let outputData = outputBuffer.floatChannelData else {
      return averageChannels(buffer)
    }

    return Array(UnsafeBufferPointer(start: outputData[0], count: Int(outputBuffer.frameLength)))
  }

  private func averageChannels(_ buffer: AVAudioPCMBuffer) -> [Float] {
    guard let channelData = buffer.floatChannelData else {
      return []
    }

    let frameLength = Int(buffer.frameLength)
    let channelCount = Int(buffer.format.channelCount)
    guard frameLength > 0 else {
      return []
    }

    if channelCount <= 1 {
      return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
    }

    var mixed = [Float](repeating: 0, count: frameLength)
    for frameIndex in 0..<frameLength {
      var sum: Float = 0
      for channelIndex in 0..<channelCount {
        sum += channelData[channelIndex][frameIndex]
      }
      mixed[frameIndex] = sum / Float(channelCount)
    }
    return mixed
  }
}

final class IOSNoOpTextDeliverer: @unchecked Sendable, TextDelivering {
  func deliver(text: String) async throws {}
}
