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
        // Record and replay real captures. The payload types, the on-disk format, the recorder,
        // the reader and the CaptureSource seam, and nothing that invents a sensor.
        .library(name: "LieDAR", targets: ["LieDAR"]),
        // The fake sensor: rooms, the raycaster, the virtual camera and SyntheticCaptureSource.
        .library(name: "LieDARSynthetic", targets: ["LieDARSynthetic"]),
        // The preview view and SimulatorControls. Draws what the synthetic camera sees.
        .library(name: "LieDARUI", targets: ["LieDARUI"]),
        // The on-device CaptureSource. On macOS this builds to the re-export alone, since every
        // ARKit line is behind a guard that requires iOS.
        .library(name: "LieDARARKit", targets: ["LieDARARKit"]),
        // `tools/make_fixture.sh` runs this to write Fixtures/synthetic-<seed>/.
        .executable(name: "liedar-fixture", targets: ["LieDARFixtureTool"]),
    ],
    targets: [
        // Payload types, the capture format, the recorder/reader and the CaptureSource seam.
        // No UIKit, CoreImage, ARKit or CoreVideo anywhere in this target, and no dependency on
        // any other target in this package. `tools/layering_check.sh` holds that line.
        .target(name: "LieDAR"),
        // Everything only a consumer who wants a fake sensor needs. Depends on the core, and
        // the core never depends back.
        .target(name: "LieDARSynthetic", dependencies: ["LieDAR"]),
        // ARKitCaptureSource, behind `#if canImport(ARKit)`. The only target that imports ARKit,
        // AVFoundation, CoreVideo or RealityKit. Core only: it records a real sensor.
        .target(name: "LieDARARKit", dependencies: ["LieDAR"]),
        // Phase 3: the preview view and the SimulatorControls overlay. SwiftUI, never ARKit. It
        // draws a `Raycaster.Frame` and walks a `SyntheticCaptureSource`, so it needs synthetic.
        .target(name: "LieDARUI", dependencies: ["LieDARSynthetic"]),
        // Phase 2: the fixture generator, a thin command line over SyntheticCaptureSource + ScriptedCapture.
        .executableTarget(name: "LieDARFixtureTool", dependencies: ["LieDARSynthetic"]),
        // Depends on every façade module: the ARKit tests live here behind a guard, so they run
        // on the simulator leg and compile away on macOS, and the preview tests need LieDARUI.
        .testTarget(name: "LieDARTests",
                    dependencies: ["LieDAR", "LieDARSynthetic", "LieDARUI", "LieDARARKit"],
                    resources: [.copy("Goldens")]),
    ],
    swiftLanguageModes: [.v6]
)
