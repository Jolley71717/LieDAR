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
        // LieDARARKit and LieDARUI are deliberately not products yet. Both targets hold a
        // placeholder that re-exports LieDAR and nothing else, so a consumer who depended on
        // either one expecting an ARKit capture source or a preview view would get a re-export
        // and no warning. The targets stay, so they keep building as they are written; the
        // products come back with the code. `tools/products_check.sh` holds the rule.
        // `tools/make_fixture.sh` runs this to write Fixtures/synthetic-<seed>/.
        .executable(name: "liedar-fixture", targets: ["LieDARFixtureTool"]),
    ],
    targets: [
        // Payload types, the capture format, the recorder/reader and the CaptureSource seam.
        // No UIKit, CoreImage, ARKit or CoreVideo anywhere in this target.
        .target(name: "LieDAR"),
        // Phase 1: ARKitCaptureSource behind `#if canImport(ARKit)`. Placeholder for now.
        .target(name: "LieDARARKit", dependencies: ["LieDAR"]),
        // Phase 3: preview view and SimulatorControls overlay. Placeholder for now.
        .target(name: "LieDARUI", dependencies: ["LieDAR"]),
        // Phase 2: the fixture generator, a thin command line over SyntheticCaptureSource + ScriptedCapture.
        .executableTarget(name: "LieDARFixtureTool", dependencies: ["LieDAR"]),
        .testTarget(name: "LieDARTests", dependencies: ["LieDAR"], resources: [.copy("Goldens")]),
    ],
    swiftLanguageModes: [.v6]
)
