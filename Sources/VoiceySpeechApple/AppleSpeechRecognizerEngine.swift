import AVFoundation
import Foundation
import Speech
import VoiceyCore

public enum AppleSpeechRecognizerError: LocalizedError {
  case speechAuthorizationDenied
  case speechRecognizerUnavailable
  case transcriptionFailed
  case onDeviceRecognitionUnavailable

  public var errorDescription: String? {
    switch self {
    case .speechAuthorizationDenied:
      return "Speech recognition permission was denied."
    case .speechRecognizerUnavailable:
      return "Speech recognizer is unavailable for this locale."
    case .transcriptionFailed:
      return "Speech recognition failed to produce a transcript."
    case .onDeviceRecognitionUnavailable:
      return "On-device speech recognition is unavailable on this device."
    }
  }
}

public final class AppleSpeechRecognizerEngine: @unchecked Sendable, SpeechEngine {
  public let identifier: String
  private let locale: Locale
  private let requiresOnDeviceRecognition: Bool
  private let sampleRate: Int

  public init(
    identifier: String = "apple-speech-ondevice",
    locale: Locale = .current,
    requiresOnDeviceRecognition: Bool = true,
    sampleRate: Int = 16_000
  ) {
    self.identifier = identifier
    self.locale = locale
    self.requiresOnDeviceRecognition = requiresOnDeviceRecognition
    self.sampleRate = sampleRate
  }

  public var isReady: Bool {
    SFSpeechRecognizer.authorizationStatus() == .authorized
  }

  public func preload(modelIdentifier: String) async throws {
    let status = await requestSpeechAuthorizationIfNeeded()
    guard status == .authorized else {
      throw AppleSpeechRecognizerError.speechAuthorizationDenied
    }
  }

  public func transcribe(samples: [Float]) async throws -> TranscriptionResult {
    guard samples.isEmpty == false else {
      throw AppleSpeechRecognizerError.transcriptionFailed
    }

    let status = await requestSpeechAuthorizationIfNeeded()
    guard status == .authorized else {
      throw AppleSpeechRecognizerError.speechAuthorizationDenied
    }

    guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
      throw AppleSpeechRecognizerError.speechRecognizerUnavailable
    }

    if requiresOnDeviceRecognition, recognizer.supportsOnDeviceRecognition == false {
      throw AppleSpeechRecognizerError.onDeviceRecognitionUnavailable
    }

    let startTime = Date()
    let tempURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("voicey-ios-\(UUID().uuidString).wav")
    defer {
      try? FileManager.default.removeItem(at: tempURL)
    }

    let wavData = PCM16WaveEncoder.encode(samples: samples, sampleRate: sampleRate, channels: 1)
    try wavData.write(to: tempURL, options: .atomic)

    let request = SFSpeechURLRecognitionRequest(url: tempURL)
    request.shouldReportPartialResults = false
    request.requiresOnDeviceRecognition = requiresOnDeviceRecognition

    let recognizedText = try await withCheckedThrowingContinuation { (
      continuation: CheckedContinuation<String, Error>
    ) in
      var task: SFSpeechRecognitionTask?
      task = recognizer.recognitionTask(with: request) { result, error in
        if let error {
          continuation.resume(throwing: error)
          task?.cancel()
          task = nil
          return
        }

        guard let result else {
          return
        }

        if result.isFinal {
          continuation.resume(returning: result.bestTranscription.formattedString)
          task?.cancel()
          task = nil
        }
      }
    }

    let text = recognizedText.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    guard text.isEmpty == false else {
      throw AppleSpeechRecognizerError.transcriptionFailed
    }

    let processingTime = Date().timeIntervalSince(startTime)
    let audioDuration = Double(samples.count) / Double(sampleRate)

    return TranscriptionResult(
      text: text,
      segments: [],
      language: locale.identifier,
      processingTime: processingTime,
      performanceMetrics: PerformanceMetrics(
        realTimeFactor: audioDuration > 0 ? processingTime / audioDuration : 0,
        audioDuration: audioDuration,
        processingTime: processingTime,
        thermalState: ProcessInfo.processInfo.thermalState
      )
    )
  }

  private func requestSpeechAuthorizationIfNeeded() async -> SFSpeechRecognizerAuthorizationStatus {
    let currentStatus = SFSpeechRecognizer.authorizationStatus()
    guard currentStatus == .notDetermined else {
      return currentStatus
    }

    return await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { status in
        continuation.resume(returning: status)
      }
    }
  }
}

private enum PCM16WaveEncoder {
  static func encode(samples: [Float], sampleRate: Int, channels: Int) -> Data {
    let bitsPerSample = 16
    let bytesPerSample = bitsPerSample / 8
    let byteRate = sampleRate * channels * bytesPerSample
    let blockAlign = channels * bytesPerSample

    var pcmData = Data(capacity: samples.count * bytesPerSample)
    for sample in samples {
      let clamped = max(-1.0, min(1.0, sample))
      var int16Sample = Int16(clamped * Float(Int16.max)).littleEndian
      pcmData.append(Data(bytes: &int16Sample, count: MemoryLayout<Int16>.size))
    }

    let dataChunkSize = UInt32(pcmData.count)
    let riffChunkSize = UInt32(36) + dataChunkSize

    var data = Data()
    data.append("RIFF".data(using: .ascii)!)
    data.append(uint32(riffChunkSize))
    data.append("WAVE".data(using: .ascii)!)
    data.append("fmt ".data(using: .ascii)!)
    data.append(uint32(16))
    data.append(uint16(1))
    data.append(uint16(UInt16(channels)))
    data.append(uint32(UInt32(sampleRate)))
    data.append(uint32(UInt32(byteRate)))
    data.append(uint16(UInt16(blockAlign)))
    data.append(uint16(UInt16(bitsPerSample)))
    data.append("data".data(using: .ascii)!)
    data.append(uint32(dataChunkSize))
    data.append(pcmData)
    return data
  }

  private static func uint16(_ value: UInt16) -> Data {
    var littleEndianValue = value.littleEndian
    return Data(bytes: &littleEndianValue, count: MemoryLayout<UInt16>.size)
  }

  private static func uint32(_ value: UInt32) -> Data {
    var littleEndianValue = value.littleEndian
    return Data(bytes: &littleEndianValue, count: MemoryLayout<UInt32>.size)
  }
}
