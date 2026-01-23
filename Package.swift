// swift-tools-version:5.9
import PackageDescription
import Foundation

// Check if building for direct distribution (includes Sparkle for auto-updates)
// Set VOICEY_DIRECT=1 environment variable when building direct distribution
let isDirectDistribution = ProcessInfo.processInfo.environment["VOICEY_DIRECT"] == "1"

// Base dependencies (always included)
var packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "2.0.0"),
    .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0")
]

// Target dependencies
var targetDependencies: [Target.Dependency] = [
    "KeyboardShortcuts",
    "WhisperKit"
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
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Voicey", targets: ["Voicey"])
    ],
    dependencies: packageDependencies,
    targets: [
        .executableTarget(
            name: "Voicey",
            dependencies: targetDependencies,
            path: "Sources/Voicey",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Metal"),
                .linkedFramework("CoreML")
            ]
        )
    ]
)