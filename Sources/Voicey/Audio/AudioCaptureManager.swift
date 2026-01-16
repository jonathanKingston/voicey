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
    private let bufferQueue = DispatchQueue(label: "com.voicetype.audiobuffer", qos: .userInteractive)
    
    private let targetSampleRate: Double = 16000.0 // Whisper requirement
    private var converter: AVAudioConverter?
    
    init() {
        setupAudioSession()
    }
    
    private func setupAudioSession() {
        // On macOS, we don't have AVAudioSession like iOS
        // Audio configuration is handled through AVAudioEngine
    }
    
    func startCapture() {
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
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            return
        }
        
        // Create converter if sample rates differ
        if inputFormat.sampleRate != targetSampleRate {
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        }
        
        // Install tap on input node
        let bufferSize: AVAudioFrameCount = 1024
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, time in
            self?.processAudioBuffer(buffer)
        }
        
        do {
            try audioEngine.start()
        } catch {
            AppLogger.audio.error("Failed to start audio engine: \(error)")
        }
    }
    
    func stopCapture() -> [Float]? {
        // Stop the tap first to prevent more data from being queued
        inputNode?.removeTap(onBus: 0)
        audioEngine?.stop()
        
        // Wait for any in-flight buffer operations to complete
        // by using a sync barrier on the queue
        var result: [Float]?
        bufferQueue.sync {
            result = audioBuffer
            audioBuffer = [] // Clear for next capture
        }
        
        // Clean up references
        audioEngine = nil
        inputNode = nil
        converter = nil
        
        let sampleCount = result?.count ?? 0
        let durationSec = Double(sampleCount) / targetSampleRate
        AppLogger.audio.info("AudioCapture: Stopped. Got \(sampleCount) samples (~\(String(format: "%.1f", durationSec))s of audio)")
        
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
        
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputFrameCount
        ) else {
            return averageChannels(buffer)
        }
        
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { inNumPackets, outStatus in
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
        let db = 20 * log10(max(rms, 0.00001))
        let normalizedLevel = (db + 60) / 60 // Assuming -60dB to 0dB range
        return max(0, min(1, normalizedLevel))
    }
    
    // MARK: - Device Selection
    
    static func availableInputDevices() -> [AVCaptureDevice] {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .externalUnknown],
            mediaType: .audio,
            position: .unspecified
        )
        return discoverySession.devices
    }
    
    static var defaultInputDevice: AVCaptureDevice? {
        AVCaptureDevice.default(for: .audio)
    }
}
