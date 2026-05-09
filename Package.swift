// swift-tools-version:5.10
import PackageDescription
import Foundation

#if os(Linux)

// Linux hosts only compile the Foundation-only core library and its tests (CI).
// The full app target is declared in the macOS branch below.
let package = Package(
  name: "Voicey",
  products: [
    .library(name: "VoiceyCore", targets: ["VoiceyCore"])
  ],
  dependencies: [],
  targets: [
    .target(
      name: "VoiceyCore",
      dependencies: [],
      path: "Sources/VoiceyCore"
    ),
    .testTarget(
      name: "VoiceyCoreTests",
      dependencies: ["VoiceyCore"],
      path: "Tests/VoiceyCoreTests"
    )
  ]
)

#else

// Check if building for direct distribution (includes Sparkle for auto-updates)
// Set VOICEY_DIRECT=1 environment variable when building direct distribution
let isDirectDistribution = ProcessInfo.processInfo.environment["VOICEY_DIRECT"] == "1"

// Base dependencies (always included)
var packageDependencies: [Package.Dependency] = [
  .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "2.0.0"),
  .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.0.0"),
  .package(url: "https://github.com/soniqo/speech-swift", branch: "main")
]

// Target dependencies
var targetDependencies: [Target.Dependency] = [
  "VoiceyCore",
  "KeyboardShortcuts",
  "WhisperKit",
  .product(name: "Qwen3ASR", package: "speech-swift"),
  .product(name: "AudioCommon", package: "speech-swift")
]

// Add Sparkle only for direct distribution builds
// This keeps the App Store build clean (no auto-update framework)
if isDirectDistribution {
  packageDependencies.append(
    .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0")
  )
  targetDependencies.append("Sparkle")
}

let package = Package(
  name: "Voicey",
  defaultLocalization: "en",
  platforms: [
    .macOS("15.0")
  ],
  products: [
    .executable(name: "Voicey", targets: ["Voicey"])
  ],
  dependencies: packageDependencies,
  targets: [
    .target(
      name: "VoiceyCore",
      dependencies: [],
      path: "Sources/VoiceyCore"
    ),
    .executableTarget(
      name: "Voicey",
      dependencies: targetDependencies,
      path: "Sources/Voicey",
      resources: [
        .process("Resources"),
        .copy("MediaRemoteAdapterBundled")
      ],
      linkerSettings: [
        .linkedFramework("AVFoundation"),
        .linkedFramework("CoreAudio"),
        .linkedFramework("Accelerate"),
        .linkedFramework("Metal"),
        .linkedFramework("CoreML")
      ]
    ),
    .testTarget(
      name: "VoiceyTests",
      dependencies: ["Voicey"],
      path: "Tests/VoiceyTests"
    ),
    .testTarget(
      name: "VoiceyCoreTests",
      dependencies: ["VoiceyCore"],
      path: "Tests/VoiceyCoreTests"
    )
  ]
)

#endif
