// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

// Flutter reaches this package through a symlink in the app's ephemeral
// folder, and SwiftPM resolves relative paths from the link, not from here.
// So the sibling LoafMediaCore is found from this file's real location.
let core = URL(fileURLWithPath: #filePath)
    .resolvingSymlinksInPath()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("LoafMediaCore")
    .path

let package = Package(
    name: "loaf_media",
    platforms: [
        .iOS("15.0"),
        .macOS("12.0"),
    ],
    products: [
        .library(name: "loaf-media", targets: ["loaf_media"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
        .package(name: "LoafMediaCore", path: core),
    ],
    targets: [
        .target(
            name: "loaf_media",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                .product(name: "LoafMediaCore", package: "LoafMediaCore"),
            ]
        )
    ]
)
