// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "AppleSpeechBenchmark",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "voicey-apple-speech-benchmark", targets: ["AppleSpeechBenchmark"]),
  ],
  targets: [
    .executableTarget(
      name: "AppleSpeechBenchmark",
      path: "Sources/AppleSpeechBenchmark"
    ),
  ]
)
