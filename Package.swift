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
        // The on-device CaptureSource. A product again as of phase 1, because the target now
        // holds ARKitCaptureSource rather than a re-export. On macOS it builds to the re-export
        // alone, since every ARKit line is behind `#if canImport(ARKit)`.
        .library(name: "LieDARARKit", targets: ["LieDARARKit"]),
        // LieDARUI is deliberately not a product yet. Its target holds a placeholder that
        // re-exports LieDAR and nothing else, so a consumer who depended on it expecting a
        // preview view would get a re-export and no warning. The target stays, so it keeps
        // building as it is written; the product comes back with the code.
        // `tools/products_check.sh` holds the rule.
        // `tools/make_fixture.sh` runs this to write Fixtures/synthetic-<seed>/.
        .executable(name: "liedar-fixture", targets: ["LieDARFixtureTool"]),
    ],
    targets: [
        // Payload types, the capture format, the recorder/reader and the CaptureSource seam.
        // No UIKit, CoreImage, ARKit or CoreVideo anywhere in this target.
        .target(name: "LieDAR"),
        // ARKitCaptureSource, behind `#if canImport(ARKit)`. The only target that imports ARKit,
        // AVFoundation, CoreVideo or RealityKit.
        .target(name: "LieDARARKit", dependencies: ["LieDAR"]),
        // Phase 3: preview view and SimulatorControls overlay. Placeholder for now.
        .target(name: "LieDARUI", dependencies: ["LieDAR"]),
        // Phase 2: the fixture generator, a thin command line over SyntheticCaptureSource + ScriptedCapture.
        .executableTarget(name: "LieDARFixtureTool", dependencies: ["LieDAR"]),
        // Depends on LieDARARKit as well as LieDAR: the ARKit tests are in this target behind
        // `#if canImport(ARKit)`, so they run on the simulator leg and compile away on macOS.
        .testTarget(name: "LieDARTests", dependencies: ["LieDAR", "LieDARARKit"], resources: [.copy("Goldens")]),
    ],
    swiftLanguageModes: [.v6]
)
