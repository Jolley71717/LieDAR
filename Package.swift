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
        // The preview view and SimulatorControls.
        .library(name: "LieDARUI", targets: ["LieDARUI"]),
        // The on-device CaptureSource. On macOS this builds to the re-export alone, since every
        // ARKit line is behind a guard that requires iOS.
        .library(name: "LieDARARKit", targets: ["LieDARARKit"]),
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
        // Phase 3: the preview view and the SimulatorControls overlay. SwiftUI, never ARKit.
        .target(name: "LieDARUI", dependencies: ["LieDAR"]),
        // Phase 2: the fixture generator, a thin command line over SyntheticCaptureSource + ScriptedCapture.
        .executableTarget(name: "LieDARFixtureTool", dependencies: ["LieDAR"]),
        // Depends on both façade modules: the ARKit tests live here behind a guard, so they run
        // on the simulator leg and compile away on macOS, and the preview tests need LieDARUI.
        .testTarget(name: "LieDARTests", dependencies: ["LieDAR", "LieDARUI", "LieDARARKit"], resources: [.copy("Goldens")]),
    ],
    swiftLanguageModes: [.v6]
)
