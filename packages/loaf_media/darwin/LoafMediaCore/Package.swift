// swift-tools-version: 5.9

import PackageDescription

// The parts of the Apple players that need neither Flutter nor AVFoundation,
// so `swift test` runs them on their own.
let package = Package(
    name: "LoafMediaCore",
    platforms: [
        .iOS("15.0"),
        .macOS("12.0"),
    ],
    products: [
        .library(name: "LoafMediaCore", targets: ["LoafMediaCore"])
    ],
    targets: [
        .target(name: "LoafMediaCore"),
        .testTarget(name: "LoafMediaCoreTests", dependencies: ["LoafMediaCore"]),
    ]
)
