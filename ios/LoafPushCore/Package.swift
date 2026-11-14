// swift-tools-version:5.9
import PackageDescription

// macOS is here only so `swift test` runs on a Mac; the extension is iOS.
let package = Package(
  name: "LoafPushCore",
  platforms: [.iOS(.v15), .macOS(.v13)],
  products: [.library(name: "LoafPushCore", targets: ["LoafPushCore"])],
  targets: [
    .target(
      name: "LoafPushCore",
      linkerSettings: [.linkedLibrary("sqlite3")]
    ),
    .testTarget(
      name: "LoafPushCoreTests",
      dependencies: ["LoafPushCore"],
      linkerSettings: [.linkedLibrary("sqlite3")]
    ),
  ]
)
