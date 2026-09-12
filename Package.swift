// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LieDAR",
    platforms: [
        .iOS(.v16),
        // macOS is a build-and-test host only: it lets `swift build` / `swift test` run without a
        // simulator. Anything iOS-only lives behind `#if canImport(...)` or in LieDARARKit/LieDARUI.
        .macOS(.v13),
    ],
    products: [
        .library(name: "LieDAR", targets: ["LieDAR"]),
        .library(name: "LieDARARKit", targets: ["LieDARARKit"]),
        .library(name: "LieDARUI", targets: ["LieDARUI"]),
    ],
    targets: [
        // Payload types, the capture format, the recorder/reader and the CaptureSource seam.
        // No UIKit, CoreImage, ARKit or CoreVideo anywhere in this target.
        .target(name: "LieDAR"),
        // Phase 1: ARKitCaptureSource behind `#if canImport(ARKit)`. Placeholder for now.
        .target(name: "LieDARARKit", dependencies: ["LieDAR"]),
        // Phase 3: preview view and SimulatorControls overlay. Placeholder for now.
        .target(name: "LieDARUI", dependencies: ["LieDAR"]),
        .testTarget(name: "LieDARTests", dependencies: ["LieDAR"]),
    ],
    swiftLanguageModes: [.v6]
)
