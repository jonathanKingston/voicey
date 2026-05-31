import AVFoundation
import Accelerate
import VoiceyCore
import os

protocol AudioCaptureManagerDelegate: AnyObject {
  func audioCaptureManager(_ manager: AudioCaptureManager, didUpdateLevel level: Float)
  func audioCaptureManager(_ manager: AudioCaptureManager, didCaptureSamples samples: [Float])
  func audioCaptureManagerDidDetectSpeechStart(_ manager: AudioCaptureManager)
  func audioCaptureManagerDidDetectSpeechEnd(_ manager: AudioCaptureManager)
}

extension AudioCaptureManagerDelegate {
  func audioCaptureManager(_ manager: AudioCaptureManager, didCaptureSamples samples: [Float]) {}
  func audioCaptureManagerDidDetectSpeechStart(_ manager: AudioCaptureManager) {}
  func audioCaptureManagerDidDetectSpeechEnd(_ manager: AudioCaptureManager) {}
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
  private let handsFreeConfiguration = HandsFreeRecordingConfiguration.default

  private var levelTimer: Timer?
  private var usesRustCaptureWorker = false
  /// Index of the next sample to read from `voicey-capture` for incremental transcription streaming.
  private var rustStreamedSampleIndex = 0
  private var recordingMode: RecordingMode = .manual
  private var handsFreeDetector: HandsFreeSpeechDetector?
  private var captureStartedAt: Date?

  init() {
    setupAudioSession()
  }

  private func setupAudioSession() {
    // On macOS, we don't have AVAudioSession like iOS
    // Audio configuration is handled through AVAudioEngine
  }

  var handsFreeWaitTimeoutDuration: TimeInterval {
    handsFreeConfiguration.waitTimeoutDuration
  }

  func startCapture(mode: RecordingMode = .manual) throws {
    prepareForCapture(mode: mode)

    if VoiceyRuntimeConfiguration.useRustCaptureHotPath {
      usesRustCaptureWorker = true
      AppLogger.audio.info("AudioCapture: Starting voicey-capture worker...")
      do {
        try runSynchronously {
          try await VoiceyCaptureWorkerSession.shared.startRecording(mode: mode)
        }
      } catch {
        AppLogger.audio.error("voicey-capture start failed: \(error.localizedDescription)")
        resetCaptureState()
        throw error
      }
      levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
        guard let self else { return }
        Task {
          do {
            let snapshot = try await VoiceyCaptureWorkerSession.shared.currentCaptureLevelSnapshot()
            self.streamRustCapturedSamplesIfNeeded(totalSamplesCaptured: snapshot.sampleCount)
            self.handleCaptureLevel(
              snapshot.level,
              totalSamplesCaptured: snapshot.sampleCount
            )
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
    bufferQueue.sync {
      audioBuffer.removeAll()
    }

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

  /// Ends the current hands-free utterance without stopping capture (continuous session).
  func finalizeHandsFreeUtterance(applyTrailingTrimHeuristic: Bool = true) throws -> CapturedAudio? {
    guard recordingMode == .handsFree else { return nil }
    return try finalizeHandsFreeUtteranceAfterEnsuringBounds(
      applyTrailingTrimHeuristic: applyTrailingTrimHeuristic)
  }

  /// Finalizes the open utterance when exiting hands-free (hotkey / cancel), including mid-phrase capture.
  func finalizeHandsFreeUtteranceForSessionEnd(applyTrailingTrimHeuristic: Bool = true) throws -> CapturedAudio? {
    guard recordingMode == .handsFree else { return nil }
    closeOpenHandsFreeUtteranceIfNeeded()
    return try finalizeHandsFreeUtteranceAfterEnsuringBounds(
      applyTrailingTrimHeuristic: applyTrailingTrimHeuristic)
  }

  func recoverHandsFreeDetectorForNextUtterance() {
    guard recordingMode == .handsFree else { return }
    let baseline = currentHandsFreeSampleCount()
    bufferQueue.sync {
      guard var detector = self.handsFreeDetector else { return }
      detector.prepareForNextUtterance(sampleBaseline: baseline)
      self.handsFreeDetector = detector
    }
  }

  private func finalizeHandsFreeUtteranceAfterEnsuringBounds(
    applyTrailingTrimHeuristic: Bool
  ) throws -> CapturedAudio? {
    guard let detector = handsFreeDetector else { return nil }
    guard let startIndex = detector.speechStartSampleIndex,
      let endIndex = detector.speechEndSampleIndex
    else {
      AppLogger.audio.warning("Hands-Free: Cannot finalize utterance without speech bounds")
      recoverHandsFreeDetectorForNextUtterance()
      return nil
    }

    if usesRustCaptureWorker {
      do {
        try streamRustCapturedSamplesBeforeStop()
        let handle = try runSynchronously {
          try await VoiceyCaptureWorkerSession.shared.drainHandsFreeUtterance(
            startSampleIndex: startIndex,
            endSampleIndex: endIndex,
            applyTrailingTrim: applyTrailingTrimHeuristic
          )
        }
        let remainingSamples = try runSynchronously {
          try await VoiceyCaptureWorkerSession.shared.currentCaptureLevelSnapshot().sampleCount
        }
        self.rustStreamedSampleIndex = remainingSamples
        bufferQueue.sync {
          guard var detector = self.handsFreeDetector else { return }
          detector.prepareForNextUtterance(sampleBaseline: remainingSamples)
          self.handsFreeDetector = detector
        }
        if handle.sampleCount == 0 {
          handle.remove()
          return .inMemory([])
        }
        return .sharedBuffer(handle)
      } catch {
        AppLogger.audio.error("voicey-capture utterance drain failed: \(error.localizedDescription)")
        recoverHandsFreeDetectorForNextUtterance()
        throw error
      }
    }

    var utterance: [Float]?
    bufferQueue.sync {
      guard var detector = self.handsFreeDetector else { return }
      let fullBuffer = self.audioBuffer
      var segment = detector.boundedSamples(from: fullBuffer)
      if applyTrailingTrimHeuristic {
        segment = self.trimTrailingLowEnergyAudio(segment)
      }
      let drainEnd = min(max(endIndex, 0), fullBuffer.count)
      if drainEnd > 0 {
        self.audioBuffer = Array(fullBuffer.dropFirst(drainEnd))
      }
      detector.prepareForNextUtterance(sampleBaseline: self.audioBuffer.count)
      self.handsFreeDetector = detector
      utterance = segment
    }
    return utterance.map { .inMemory($0) }
  }

  private func closeOpenHandsFreeUtteranceIfNeeded() {
    bufferQueue.sync {
      guard var detector = self.handsFreeDetector else { return }
      guard detector.phase == .recording else { return }
      let endIndex = self.currentHandsFreeSampleCount()
      detector.forceEndUtterance(at: endIndex)
      self.handsFreeDetector = detector
    }
  }

  private func currentHandsFreeSampleCount() -> Int {
    if usesRustCaptureWorker {
      if let count = try? runSynchronously({
        try await VoiceyCaptureWorkerSession.shared.currentCaptureLevelSnapshot().sampleCount
      }) {
        return count
      }
      return approximateWorkerSampleCount()
    }
    return bufferQueue.sync { audioBuffer.count }
  }

  func stopCapture(applyTrailingTrimHeuristic: Bool = true) throws -> CapturedAudio? {
    defer { resetCaptureState() }

    if usesRustCaptureWorker {
      usesRustCaptureWorker = false
      levelTimer?.invalidate()
      levelTimer = nil
      delegate?.audioCaptureManager(self, didUpdateLevel: 0)
      do {
        try streamRustCapturedSamplesBeforeStop()
        let handle = try runSynchronously {
          try await VoiceyCaptureWorkerSession.shared.stopRecording(
            applyTrailingTrim: applyTrailingTrimHeuristic)
        }
        if recordingMode == .handsFree, let handsFreeDetector {
          if let slice = handsFreeDetector.boundedSlice(in: handle.sampleCount) {
            let slicedHandle = PCMBufferHandle(
              shmName: handle.shmName,
              sampleCount: slice.count,
              sampleRate: handle.sampleRate,
              sampleOffset: slice.offset
            )
            let durationSec = slicedHandle.durationSeconds
            AppLogger.audio.info(
              "AudioCapture (voicey-capture, hands-free): \(slice.count) samples (~\(String(format: "%.1f", durationSec))s) offset \(slice.offset)"
            )
            return .sharedBuffer(slicedHandle)
          }
          handle.remove()
          AppLogger.audio.info("AudioCapture (voicey-capture, hands-free): no speech detected")
          return .inMemory([])
        }
        let durationSec = handle.durationSeconds
        AppLogger.audio.info(
          "AudioCapture (voicey-capture): \(handle.sampleCount) samples (~\(String(format: "%.1f", durationSec))s)"
        )
        return .sharedBuffer(handle)
      } catch {
        AppLogger.audio.error("voicey-capture stop failed: \(error.localizedDescription)")
        throw error
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
      result = trimTrailingLowEnergyAudio(boundedSamplesIfNeeded(from: capturedAudio))
    } else if let capturedAudio = result {
      result = boundedSamplesIfNeeded(from: capturedAudio)
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

    return result.map { .inMemory($0) }
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
      guard let self else { return }
      self.audioBuffer.append(contentsOf: samples)
      self.delegate?.audioCaptureManager(self, didCaptureSamples: samples)
      self.consumeHandsFreeLevel(level, totalSamplesCaptured: self.audioBuffer.count)
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
    let formattedTrimmedSeconds = String(format: "%.2f", trimmedSeconds)
    AppLogger.audio.info(
      "AudioCapture: Trimmed \(trimmedSampleCount) trailing low-energy samples (~\(formattedTrimmedSeconds)s)"
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

  private func prepareForCapture(mode: RecordingMode) {
    recordingMode = mode
    captureStartedAt = Date()
    rustStreamedSampleIndex = 0
    handsFreeDetector = mode == .handsFree
      ? HandsFreeSpeechDetector(configuration: handsFreeConfiguration)
      : nil
  }

  private func resetCaptureState() {
    captureStartedAt = nil
    handsFreeDetector = nil
    recordingMode = .manual
    rustStreamedSampleIndex = 0
  }

  private func streamRustCapturedSamplesIfNeeded(totalSamplesCaptured: Int) {
    guard usesRustCaptureWorker, totalSamplesCaptured > rustStreamedSampleIndex else { return }
    do {
      let read = try runSynchronously {
        try await VoiceyCaptureWorkerSession.shared.readCapturedSamples(
          since: rustStreamedSampleIndex)
      }
      rustStreamedSampleIndex = read.totalSampleCount
      guard !read.samples.isEmpty else { return }
      delegate?.audioCaptureManager(self, didCaptureSamples: read.samples)
    } catch {
      AppLogger.audio.error(
        "voicey-capture read_captured_samples failed: \(error.localizedDescription)")
    }
  }

  private func streamRustCapturedSamplesBeforeStop() throws {
    let total = try runSynchronously {
      try await VoiceyCaptureWorkerSession.shared.currentCaptureLevelSnapshot().sampleCount
    }
    streamRustCapturedSamplesIfNeeded(totalSamplesCaptured: total)
  }

  private func handleCaptureLevel(_ level: Float, totalSamplesCaptured: Int) {
    Task { @MainActor [weak self] in
      guard let self = self else { return }
      self.delegate?.audioCaptureManager(self, didUpdateLevel: level)
    }

    bufferQueue.async { [weak self] in
      self?.consumeHandsFreeLevel(level, totalSamplesCaptured: totalSamplesCaptured)
    }
  }

  private func consumeHandsFreeLevel(_ level: Float, totalSamplesCaptured: Int) {
    guard recordingMode == .handsFree, var detector = handsFreeDetector else { return }

    let events = detector.consume(level: level, totalSamplesCaptured: totalSamplesCaptured)
    handsFreeDetector = detector

    for event in events {
      switch event {
      case .speechStarted:
        Task { @MainActor [weak self] in
          guard let self else { return }
          self.delegate?.audioCaptureManagerDidDetectSpeechStart(self)
        }
      case .speechEnded:
        Task { @MainActor [weak self] in
          guard let self else { return }
          self.delegate?.audioCaptureManagerDidDetectSpeechEnd(self)
        }
      }
    }
  }

  private func boundedSamplesIfNeeded(from samples: [Float]) -> [Float] {
    guard recordingMode == .handsFree, let handsFreeDetector else { return samples }
    return handsFreeDetector.boundedSamples(from: samples)
  }

  private func approximateWorkerSampleCount() -> Int {
    guard let captureStartedAt else { return 0 }
    let elapsed = max(0, Date().timeIntervalSince(captureStartedAt))
    return Int((elapsed * targetSampleRate).rounded())
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
