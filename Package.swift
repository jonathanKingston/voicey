// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Voicey",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Voicey", targets: ["Voicey"])
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "2.0.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0")
    ],
    targets: [
        .executableTarget(
            name: "Voicey",
            dependencies: [
                "KeyboardShortcuts",
                "WhisperKit"
            ],
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