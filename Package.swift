// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WhisperFlow",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "WhisperFlow",
            path: "Sources/WhisperFlow",
            exclude: ["Info.plist"],
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ],
            linkerSettings: [
                // Required frameworks
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Speech"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("NaturalLanguage"),
                .linkedFramework("Carbon"),
            ]
        )
    ]
)
