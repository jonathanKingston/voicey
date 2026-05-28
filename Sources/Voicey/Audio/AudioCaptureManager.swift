import AVFoundation
import Accelerate
import os

protocol AudioCaptureManagerDelegate: AnyObject {
  func audioCaptureManager(_ manager: AudioCaptureManager, didUpdateLevel level: Float)
}

final class AudioCaptureManager {
  weak var delegate: AudioCaptureManagerDelegate?

  private var audioEngine: AVAudioEngine?
  private var inputNode: AVAudioInputNode?
  private var audioBuffer: [Float] = []
  private let bufferQueue = DispatchQueue(label: "work.voicey.audiobuffer", qos: .userInteractive)

  private let targetSampleRate: Double = 16000.0  // Whisper requirement
  private var converter: AVAudioConverter?

  // Trailing trim constants to reduce end-of-recording keyboard artifacts.
  private let maxTrailingTrimSeconds: Double = 0.5
  private let trailingRMSWindowSeconds: Double = 0.02
  private let trailingRMSHopSeconds: Double = 0.01
  private let trailingSilenceRMSThreshold: Float = 0.01
  private let minimumRemainingAudioSeconds: Double = 0.3
  private let minimumTrimSeconds: Double = 0.08

  private var levelTimer: Timer?
  private var usesRustCaptureWorker = false

  init() {
    setupAudioSession()
  }

  private func setupAudioSession() {
    // On macOS, we don't have AVAudioSession like iOS
    // Audio configuration is handled through AVAudioEngine
  }

  func startCapture() {
    if VoiceyRuntimeConfiguration.useRustCaptureHotPath {
      usesRustCaptureWorker = true
      AppLogger.audio.info("AudioCapture: Starting voicey-capture worker...")
      Task {
        do {
          try await VoiceyCaptureWorkerSession.shared.startRecording()
        } catch {
          AppLogger.audio.error("voicey-capture start failed: \(error.localizedDescription)")
        }
      }
      levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
        guard let self else { return }
        Task {
          do {
            let level = try await VoiceyCaptureWorkerSession.shared.currentInputLevel()
            await MainActor.run {
              self.delegate?.audioCaptureManager(self, didUpdateLevel: level)
            }
          } catch {
            // Worker may still be starting; keep last level.
          }
        }
      }
      if let levelTimer {
        RunLoop.main.add(levelTimer, forMode: .common)
      }
      return
    }

    usesRustCaptureWorker = false
    AppLogger.audio.info("AudioCapture: Starting capture...")
    audioBuffer.removeAll()

    audioEngine = AVAudioEngine()
    guard let audioEngine = audioEngine else {
      AppLogger.audio.error("AudioCapture: Failed to create audio engine")
      return
    }

    inputNode = audioEngine.inputNode
    guard let inputNode = inputNode else {
      AppLogger.audio.error("AudioCapture: Failed to get input node")
      return
    }

    let inputFormat = inputNode.outputFormat(forBus: 0)

    // Create output format at 16kHz mono for Whisper
    guard
      let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: targetSampleRate,
        channels: 1,
        interleaved: false
      )
    else {
      return
    }

    // Create converter if sample rates differ
    if inputFormat.sampleRate != targetSampleRate {
      converter = AVAudioConverter(from: inputFormat, to: outputFormat)
    }

    // Install tap on input node
    let bufferSize: AVAudioFrameCount = 1024
    inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
      self?.processAudioBuffer(buffer)
    }

    do {
      try audioEngine.start()
    } catch {
      AppLogger.audio.error("Failed to start audio engine: \(error)")
    }
  }

  func stopCapture(applyTrailingTrimHeuristic: Bool = true) -> [Float]? {
    if usesRustCaptureWorker {
      let wasRustCapture = true
      usesRustCaptureWorker = false
      levelTimer?.invalidate()
      levelTimer = nil
      delegate?.audioCaptureManager(self, didUpdateLevel: 0)
      do {
        var samples = try runSynchronously {
          try await VoiceyCaptureWorkerSession.shared.stopRecording()
        }
        // voicey-capture applies trailing trim before returning PCM.
        if !wasRustCapture, applyTrailingTrimHeuristic {
          samples = trimTrailingLowEnergyAudio(samples) ?? samples
        }
        let durationSec = Double(samples.count) / targetSampleRate
        AppLogger.audio.info(
          "AudioCapture (voicey-capture): \(samples.count) samples (~\(String(format: "%.1f", durationSec))s)"
        )
        return samples
      } catch {
        AppLogger.audio.error("voicey-capture stop failed: \(error.localizedDescription)")
        return nil
      }
    }

    // Stop the tap first to prevent more data from being queued
    inputNode?.removeTap(onBus: 0)
    audioEngine?.stop()

    // Wait for any in-flight buffer operations to complete
    // by using a sync barrier on the queue
    var result: [Float]?
    bufferQueue.sync {
      result = audioBuffer
      audioBuffer = []  // Clear for next capture
    }

    if applyTrailingTrimHeuristic, let capturedAudio = result {
      result = trimTrailingLowEnergyAudio(capturedAudio)
    }

    // Clean up references
    audioEngine = nil
    inputNode = nil
    converter = nil

    let sampleCount = result?.count ?? 0
    let durationSec = Double(sampleCount) / targetSampleRate
    AppLogger.audio.info(
      "AudioCapture: Stopped. Got \(sampleCount) samples (~\(String(format: "%.1f", durationSec))s of audio)"
    )

    return result
  }

  private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
    guard let channelData = buffer.floatChannelData else { return }

    let frameLength = Int(buffer.frameLength)
    let inputFormat = buffer.format

    // Convert to mono 16kHz if needed
    var samples: [Float]

    if inputFormat.sampleRate != targetSampleRate || inputFormat.channelCount > 1 {
      samples = convertBuffer(buffer)
    } else {
      samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
    }

    // Calculate audio level for UI
    let level = calculateRMSLevel(samples)
    Task { @MainActor [weak self] in
      guard let self = self else { return }
      self.delegate?.audioCaptureManager(self, didUpdateLevel: level)
    }

    // Append to buffer
    bufferQueue.async { [weak self] in
      self?.audioBuffer.append(contentsOf: samples)
    }
  }

  private func convertBuffer(_ buffer: AVAudioPCMBuffer) -> [Float] {
    guard let converter = converter else {
      // Fallback: just average channels and return
      return averageChannels(buffer)
    }

    let inputFormat = buffer.format
    let outputFormat = converter.outputFormat

    // Calculate output frame count based on sample rate ratio
    let ratio = outputFormat.sampleRate / inputFormat.sampleRate
    let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

    guard
      let outputBuffer = AVAudioPCMBuffer(
        pcmFormat: outputFormat,
        frameCapacity: outputFrameCount
      )
    else {
      return averageChannels(buffer)
    }

    var error: NSError?
    let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
      outStatus.pointee = .haveData
      return buffer
    }

    if status == .error || error != nil {
      return averageChannels(buffer)
    }

    guard let channelData = outputBuffer.floatChannelData else {
      return averageChannels(buffer)
    }

    return Array(UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))
  }

  private func averageChannels(_ buffer: AVAudioPCMBuffer) -> [Float] {
    guard let channelData = buffer.floatChannelData else { return [] }

    let frameLength = Int(buffer.frameLength)
    let channelCount = Int(buffer.format.channelCount)

    if channelCount == 1 {
      return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
    }

    var result = [Float](repeating: 0, count: frameLength)
    for frame in 0..<frameLength {
      var sum: Float = 0
      for channel in 0..<channelCount {
        sum += channelData[channel][frame]
      }
      result[frame] = sum / Float(channelCount)
    }
    return result
  }

  private func calculateRMSLevel(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }

    var rms: Float = 0
    vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))

    // Convert to dB and normalize to 0-1 range
    let decibels = 20 * log10(max(rms, 0.00001))
    let normalizedLevel = (decibels + 60) / 60  // Assuming -60dB to 0dB range
    return max(0, min(1, normalizedLevel))
  }

  /// Trim low-energy audio from the end (up to a bounded amount) to reduce
  /// stop-key noise/silence hallucinations without clipping real speech endings.
  private func trimTrailingLowEnergyAudio(_ samples: [Float]) -> [Float] {
    guard !samples.isEmpty else { return samples }

    let maxTrimSamples = Int(maxTrailingTrimSeconds * targetSampleRate)
    let windowSamples = max(1, Int(trailingRMSWindowSeconds * targetSampleRate))
    let hopSamples = max(1, Int(trailingRMSHopSeconds * targetSampleRate))
    let minRemainingSamples = Int(minimumRemainingAudioSeconds * targetSampleRate)
    let minTrimSamples = Int(minimumTrimSeconds * targetSampleRate)

    guard samples.count > windowSamples else { return samples }
    let boundedMaxTrim = min(maxTrimSamples, samples.count - windowSamples)
    guard boundedMaxTrim >= minTrimSamples else { return samples }

    let scanStart = samples.count - boundedMaxTrim
    var scanIndex = samples.count - windowSamples
    var keepEndIndex = samples.count

    while scanIndex >= scanStart {
      let rms = rms(in: samples, start: scanIndex, count: windowSamples)
      if rms > trailingSilenceRMSThreshold {
        keepEndIndex = scanIndex + windowSamples
        break
      }
      scanIndex -= hopSamples
    }

    keepEndIndex = max(keepEndIndex, minRemainingSamples)
    let trimmedSampleCount = samples.count - keepEndIndex
    guard trimmedSampleCount >= minTrimSamples else { return samples }

    let trimmedSeconds = Double(trimmedSampleCount) / targetSampleRate
    AppLogger.audio.info(
      "AudioCapture: Trimmed \(trimmedSampleCount) trailing low-energy samples (~\(String(format: "%.2f", trimmedSeconds))s)"
    )

    return Array(samples.prefix(keepEndIndex))
  }

  private func rms(in samples: [Float], start: Int, count: Int) -> Float {
    guard start >= 0, count > 0, start + count <= samples.count else { return 0 }

    return samples.withUnsafeBufferPointer { buffer in
      guard let base = buffer.baseAddress else { return 0 }
      var rms: Float = 0
      vDSP_rmsqv(base.advanced(by: start), 1, &rms, vDSP_Length(count))
      return rms
    }
  }

  // MARK: - Device Selection

  static func availableInputDevices() -> [AVCaptureDevice] {
    let discoverySession = AVCaptureDevice.DiscoverySession(
      deviceTypes: [.microphone, .external],
      mediaType: .audio,
      position: .unspecified
    )
    return discoverySession.devices
  }

  static var defaultInputDevice: AVCaptureDevice? {
    AVCaptureDevice.default(for: .audio)
  }

  private func runSynchronously<T>(_ operation: @escaping () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<T, Error>?
    Task {
      do {
        result = .success(try await operation())
      } catch {
        result = .failure(error)
      }
      semaphore.signal()
    }
    semaphore.wait()
    return try result!.get()
  }
}
