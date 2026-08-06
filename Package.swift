// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pawvis",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure gesture/dictation logic — no AppKit/AVFoundation, fully unit-testable.
        .target(
            name: "PawvisCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The menu bar app: camera, Vision hand tracking, mouse control, overlay, dictation.
        .executableTarget(
            name: "Pawvis",
            dependencies: ["PawvisCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PawvisCoreTests",
            dependencies: ["PawvisCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
