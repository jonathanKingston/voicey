import Foundation

/// Shared PCM files under the system temp directory (`voicey_pcm_*.pcm`).
///
/// Spec (protocol v1): matches the Rust `voicey-pcm` crate — little-endian f32 mono samples;
/// name is `voicey_pcm_{uuid}` with UUID v4 hex (no dashes); file is `{name}.pcm` in temp dir.
enum SharedMemoryPCM {
  static func write(samples: [Float]) throws -> String {
    let name = "voicey_pcm_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    let url = fileURL(for: name)
    var data = Data(capacity: samples.count * MemoryLayout<Float>.size)
    for sample in samples {
      var littleEndian = sample.bitPattern.littleEndian
      withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
    try data.write(to: url, options: .atomic)
    return name
  }

  static func read(name: String, sampleCount: Int) throws -> [Float] {
    let url = fileURL(for: name)
    let data = try Data(contentsOf: url)
    let expected = sampleCount * MemoryLayout<Float>.size
    guard data.count >= expected else {
      throw SharedMemoryPCMError.bufferTooSmall
    }
    return data.withUnsafeBytes { rawBuffer in
      let bound = rawBuffer.bindMemory(to: Float.self)
      return Array(bound.prefix(sampleCount))
    }
  }

  static func remove(name: String) {
    try? FileManager.default.removeItem(at: fileURL(for: name))
  }

  static func fileURL(for name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("\(name).pcm")
  }
}

enum SharedMemoryPCMError: LocalizedError {
  case bufferTooSmall

  var errorDescription: String? {
    switch self {
    case .bufferTooSmall:
      return "Shared PCM buffer is smaller than expected"
    }
  }
}
