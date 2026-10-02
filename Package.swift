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
            // N6 (2026-10-02): declare Resources so `swift build` stops
            // warning about 11 unhandled files (AppIcon.icns + iconset PNGs).
            resources: [.process("Resources")],
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
