// swift-tools-version:6.0
import PackageDescription

/// Standalone Apple SpeechAnalyzer eval CLI (macOS 26+).
///
/// Kept out of the main Voicey target so `make build` on macOS 15 CI stays green
/// until the project adopts the macOS 26 SDK.
let package = Package(
  name: "voicey-apple-speech-benchmark",
  platforms: [
    .macOS(.v26)
  ],
  products: [
    .executable(
      name: "voicey-apple-speech-benchmark",
      targets: ["AppleSpeechBenchmark"]
    )
  ],
  targets: [
    .executableTarget(
      name: "AppleSpeechBenchmark",
      path: "Sources/AppleSpeechBenchmark"
    )
  ]
)
