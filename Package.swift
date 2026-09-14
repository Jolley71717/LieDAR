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
        // The preview view and SimulatorControls, added back as a product now that the target
        // holds them. See `tools/products_check.sh` for the rule a product has to meet.
        .library(name: "LieDARUI", targets: ["LieDARUI"]),
        // LieDARARKit is deliberately not a product yet. Its target holds a placeholder that
        // re-exports LieDAR and nothing else, so a consumer who depended on it expecting an
        // ARKit capture source would get a re-export and no warning. The target stays, so it
        // keeps building as the real thing is written; the product comes back with the code.
        // `tools/make_fixture.sh` runs this to write Fixtures/synthetic-<seed>/.
        .executable(name: "liedar-fixture", targets: ["LieDARFixtureTool"]),
    ],
    targets: [
        // Payload types, the capture format, the recorder/reader and the CaptureSource seam.
        // No UIKit, CoreImage, ARKit or CoreVideo anywhere in this target.
        .target(name: "LieDAR"),
        // Phase 1: ARKitCaptureSource behind `#if canImport(ARKit)`. Placeholder for now.
        .target(name: "LieDARARKit", dependencies: ["LieDAR"]),
        // Phase 3: the preview view and the SimulatorControls overlay. SwiftUI, never ARKit.
        .target(name: "LieDARUI", dependencies: ["LieDAR"]),
        // Phase 2: the fixture generator, a thin command line over SyntheticCaptureSource + ScriptedCapture.
        .executableTarget(name: "LieDARFixtureTool", dependencies: ["LieDAR"]),
        .testTarget(name: "LieDARTests", dependencies: ["LieDAR", "LieDARUI"], resources: [.copy("Goldens")]),
    ],
    swiftLanguageModes: [.v6]
)
