import Foundation
import simd
import XCTest
@testable import LieDAR

/// End to end: a scripted capture through `ScriptedCapture` (gate + `CaptureRecorder`) into a
/// temp folder, asserted with values not presence, then parsed whole by `CaptureReader`.
final class SyntheticSourceTests: XCTestCase {

    /// The canonical 3-second capture: canonical room, a 4 s tour cut to its first 3 s, no
    /// colour, suite-default degradation, a loop closure at 2.5 s, not paced to the clock.
    static func threeSecondConfiguration(seed: UInt64 = 21) -> SyntheticCaptureSource.Configuration {
        let tour = CameraPath.tour(of: .canonical, seconds: 4).truncated(to: 3)   // still 1 s, a 1.5 s leg, a third of the next
        XCTAssertEqual(tour.duration, 3)
        XCTAssertEqual(tour.waypoints.count, 4)
        var configuration = SyntheticCaptureSource.Configuration(room: .parametric(.canonical), path: tour,
                                                                  degradation: DegradationModel(seed: seed))
        configuration.chunker.seed = seed
        configuration.colorResolution = nil
        configuration.realTime = false
        configuration.loopClosure = .init(time: 2.5, translation: SIMD3(0.03, 0.01, -0.02))
        return configuration
    }

    func testThreeSecondCaptureWritesTheExpectedFolder() async throws {
        let folder = try makeScratchDirectory()
        let source = SyntheticCaptureSource(configuration: Self.threeSecondConfiguration())
        XCTAssertTrue(source.isAvailable)
        XCTAssertTrue(source.cameraAuthorized)

        let report = try await ScriptedCapture.record(from: source, to: folder)

        // Samples: 3 s at 30 Hz is 91 ticks; the first 30 are not normal (unavailable, initialising).
        XCTAssertEqual(report.samplesSeen, 91)
        XCTAssertEqual(report.normalSamples, 61)
        // Frames: the gate passes the first normal frame, then one per 0.15 m / 10° / 0.5 s.
        // The 1.5 s leg covers 1.6 m and 90°, so roughly a frame every 0.14 s of the leg.
        XCTAssertEqual(report.framesWritten, 13, "frames written ≠ frames fed: \(report.framesWritten) of \(report.normalSamples) normal samples")
        XCTAssertEqual(report.framesAdmitted, report.framesWritten)
        XCTAssertEqual(report.framesDropped, 0)
        XCTAssertEqual(report.anchorsAdded, 48, "anchors added, churn re-adds included")
        XCTAssertEqual(report.anchorsUpdated, 78, "updates: growth plus the loop closure re-emitting every anchor discovered by 2.5 s")
        XCTAssertEqual(report.anchorsRemoved, 2, "seeded churn")
        XCTAssertEqual(report.mesh.anchorCount, 46, "anchors discovered in 3 s")

        // The folder, by the reader.
        let reader = CaptureReader(folderURL: folder)
        XCTAssertTrue(reader.isFinished)
        let manifest = try reader.manifest()
        XCTAssertEqual(manifest.formatVersion, 2)
        XCTAssertEqual(manifest.deviceModel, "LieDAR-synthetic")
        XCTAssertEqual(manifest.iosVersion, "synthetic")
        XCTAssertEqual(manifest.frameCount, 13)
        XCTAssertEqual(manifest.meshAnchorCount, 46)
        XCTAssertEqual(manifest.normalTrackingFrameCount, 61)
        XCTAssertEqual(manifest.totalTrackingFrameCount, 91)
        XCTAssertFalse(manifest.worldMapSaved)
        XCTAssertEqual(manifest.endedAt.timeIntervalSince(manifest.startedAt), 3, "3 s of camera time")
        XCTAssertEqual(reader.contents, CaptureContents(frameCount: 13, meshAnchorCount: 46))
        XCTAssertEqual(CaptureFormat.disposition(of: reader.contents), .keep)

        // Frames: every one complete, depth non-zero and plausible, confidence present, no colour.
        let indices = reader.completeFrameIndices()
        XCTAssertEqual(indices, Array(0..<13))
        XCTAssertEqual(reader.incompleteFrameIndices(), [])
        var lastTransform: simd_float4x4?
        var lastTimestamp: TimeInterval = 0
        for index in indices {
            let meta = try reader.frameMeta(index)
            XCTAssertEqual(meta.index, index)
            XCTAssertEqual(meta.state, .normal)
            XCTAssertEqual(meta.depthResolution, PixelSize(width: 256, height: 192))
            XCTAssertEqual(meta.imageResolution, PixelSize(width: 1920, height: 1440), "no colour, so the intrinsics stay at the sensor's size")
            XCTAssertEqual(meta.intrinsics, [1340, 0, 0, 0, 1340, 0, 960, 720, 1])
            let depth = try reader.depth(index)
            XCTAssertEqual(depth.data.count, 256 * 192 * 4)
            let values = depth.values()
            let nonZero = values.filter { $0 > 0 }.count
            XCTAssertEqual(nonZero, values.count, "frame \(index): every depth pixel is non-zero in a closed room")
            XCTAssertGreaterThan(values.max()!, 1.0, "frame \(index): sees at least a metre")
            XCTAssertLessThan(values.max()!, 7.0, "frame \(index): a 5 × 4 room is never 7 m deep")
            let confidence = try XCTUnwrap(reader.confidence(index))
            XCTAssertEqual(confidence.data.count, 256 * 192)
            XCTAssertGreaterThan(confidence.values().filter { $0 == 2 }.count, 1000, "frame \(index): plenty of high confidence")
            XCTAssertNil(reader.colorJPEG(index), "no colour was configured")
            if let last = lastTransform, let now = meta.cameraMatrix {
                let moved = simd_length(now.translation - last.translation)
                let turned = VirtualCamera.angleDegrees(last, now)
                let waited = meta.timestamp - lastTimestamp
                XCTAssertTrue(moved >= 0.15 || turned >= 10 || waited >= 0.5,
                              "frame \(index) was written without moving: \(moved) m, \(turned)°, \(waited) s")
            }
            lastTransform = meta.cameraMatrix
            lastTimestamp = meta.timestamp
        }

        // Mesh: anchors.json count, every anchor loads, and the degradation shows in the labels.
        let anchors = try reader.anchors()
        XCTAssertEqual(anchors.count, 46)
        var faces = 0, unlabelled = 0, shifted = 0, unshifted = 0
        for meta in anchors {
            let anchor = try reader.anchor(meta)
            XCTAssertNoThrow(try anchor.validate())
            faces += anchor.faceCount
            unlabelled += anchor.classArray().filter { $0 == 0 }.count
            // Loop closure at 2.5 s: anchors discovered by then sit 3 cm off the half-metre grid;
            // anchors discovered in the last half second were born in the corrected frame.
            let x = anchor.transform.translation.x + 0.5
            let fraction = x - x.rounded()
            if abs(fraction - 0.03) < 1e-5 { shifted += 1 } else if abs(fraction) < 1e-5 { unshifted += 1 }
        }
        XCTAssertEqual(shifted + unshifted, anchors.count, "every origin is either shifted by the loop closure or on the grid")
        XCTAssertEqual(shifted, 40, "anchors moved by the loop closure")
        XCTAssertEqual(unshifted, 6, "anchors discovered after it")
        XCTAssertEqual(faces, manifest.totalFaces)
        XCTAssertEqual(Double(unlabelled) / Double(faces), 0.30, accuracy: 0.04, "\(unlabelled) of \(faces) faces unlabelled")
        let ply = try text(of: folder.appendingPathComponent("mesh.ply"))
        XCTAssertTrue(ply.hasPrefix("ply\nformat ascii 1.0\n"))
        XCTAssertTrue(ply.contains("element vertex \(manifest.totalVertices)\n"))
        XCTAssertTrue(ply.contains("element face \(manifest.totalFaces)\n"))
    }

    func testZeroFramesVariantProducesAnEmptyCaptureToDiscard() async throws {
        let folder = try makeScratchDirectory()
        var configuration = Self.threeSecondConfiguration()
        configuration.zeroFrames = true
        let source = SyntheticCaptureSource(configuration: configuration)
        let report = try await ScriptedCapture.record(from: source, to: folder)
        XCTAssertEqual(report.samplesSeen, 0)
        XCTAssertEqual(report.framesWritten, 0)
        XCTAssertEqual(report.mesh.anchorCount, 0)
        XCTAssertEqual(source.meshSnapshot(), [])
        let reader = CaptureReader(folderURL: folder)
        XCTAssertTrue(reader.isFinished)
        XCTAssertEqual(reader.contents, CaptureContents(frameCount: 0, meshAnchorCount: 0))
        XCTAssertEqual(CaptureFormat.disposition(of: reader.contents), .discardEmpty)
        XCTAssertEqual(try text(of: folder.appendingPathComponent("mesh/anchors.json")), "[\n\n]")
    }

    func testMaterializedFrameCarriesColourAtTheConfiguredSize() throws {
        var configuration = Self.threeSecondConfiguration()
        configuration.colorResolution = PixelSize(width: 960, height: 720)
        let source = SyntheticCaptureSource(configuration: configuration)
        let frame = source.materialize(source.camera.tick(45))
        let color = try XCTUnwrap(frame.color)
        XCTAssertEqual(color.pixelFormat, .bgra32)
        XCTAssertEqual(color.width, 960)
        XCTAssertEqual(color.height, 720)
        XCTAssertEqual(frame.meta.imageResolution, PixelSize(width: 960, height: 720))
        XCTAssertEqual(frame.meta.intrinsics[0], 670, "fx scaled to 960 wide")
        XCTAssertEqual(frame.meta.intrinsics[6], 480)
        // Flat-shaded per class: the pixel under the centre is the wall colour (BGRA order).
        let bytes = color.planes[0].data
        let offset = 360 * color.planes[0].bytesPerRow + 480 * 4
        let wall = CaptureFormat.classificationColor(MeshClassification.wall.rawValue)
        // Annotated on both sides. Two untyped array literals in one XCTAssertEqual made Xcode
        // 26.1.1 give up type-checking the expression; 26.5 managed it, so only CI caught it.
        let centre: [UInt8] = [bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3]]
        let expected: [UInt8] = [wall.b, wall.g, wall.r, 255]
        XCTAssertEqual(centre, expected, "the pixel under the centre is the wall colour, BGRA")
        let distinct: Set<[UInt8]> = Set(stride(from: 0, to: bytes.count, by: 4).map {
            let triple: [UInt8] = [bytes[$0], bytes[$0 + 1], bytes[$0 + 2]]
            return triple
        })
        XCTAssertGreaterThanOrEqual(distinct.count, 3, "several classes are in view: \(distinct.count) colours")
    }

    func testRealTimePacingHoldsTheFrameRate() async throws {
        var configuration = Self.threeSecondConfiguration()
        configuration.realTime = true
        configuration.path = CameraPath(waypoints: [
            .init(position: SIMD3(2.5, 1.4, 3), lookAt: SIMD3(2.5, 1.4, 0), duration: 0),
            .init(position: SIMD3(2.5, 1.4, 3), lookAt: SIMD3(2.5, 1.4, 0), duration: 0.5),
        ])
        let source = SyntheticCaptureSource(configuration: configuration)
        let start = Date()
        try source.start()
        var count = 0
        for await _ in source.samples { count += 1 }
        let elapsed = Date().timeIntervalSince(start)
        source.stop()
        XCTAssertEqual(count, 16, "0.5 s at 30 Hz, both ends inclusive")
        XCTAssertGreaterThanOrEqual(elapsed, 0.45, "paced to the clock: \(elapsed) s")
    }

    func testStopEndsTheStreamsEarly() async throws {
        let source = SyntheticCaptureSource(configuration: Self.threeSecondConfiguration())
        try source.start()
        var count = 0
        for await _ in source.samples {
            count += 1
            if count == 5 { source.stop() }
        }
        XCTAssertLessThan(count, 91, "stopped after \(count) samples")
        XCTAssertGreaterThanOrEqual(count, 5)
    }

    // MARK: FrameGate

    func testGateAdmitsOnMovementTurnOrTimeAndNeverWhenNotNormal() {
        var gate = FrameGate()
        let still = VirtualCamera.lookAt(from: SIMD3(0, 1.4, 0), to: SIMD3(0, 1.4, -5))
        XCTAssertFalse(gate.admit(transform: still, timestamp: 0, trackingState: .limitedInitializing))
        XCTAssertFalse(gate.admit(transform: still, timestamp: 0.1, trackingState: .notAvailable))
        XCTAssertTrue(gate.admit(transform: still, timestamp: 1.0, trackingState: .normal), "first normal frame")
        XCTAssertFalse(gate.admit(transform: still, timestamp: 1.1, trackingState: .normal), "nothing changed")
        var moved = still
        moved.columns.3.x = 0.14
        XCTAssertFalse(gate.admit(transform: moved, timestamp: 1.2, trackingState: .normal), "0.14 m is under 0.15")
        moved.columns.3.x = 0.15
        XCTAssertTrue(gate.admit(transform: moved, timestamp: 1.2, trackingState: .normal), "0.15 m")
        let turned9 = VirtualCamera.lookAt(from: SIMD3(0.15, 1.4, 0), to: SIMD3(0.15 + 5 * sin(9 * Float.pi / 180), 1.4, -5 * cos(9 * Float.pi / 180)))
        XCTAssertFalse(gate.admit(transform: turned9, timestamp: 1.3, trackingState: .normal), "9° is under 10°")
        let turned11 = VirtualCamera.lookAt(from: SIMD3(0.15, 1.4, 0), to: SIMD3(0.15 + 5 * sin(11 * Float.pi / 180), 1.4, -5 * cos(11 * Float.pi / 180)))
        XCTAssertTrue(gate.admit(transform: turned11, timestamp: 1.3, trackingState: .normal), "11°")
        XCTAssertFalse(gate.admit(transform: turned11, timestamp: 1.79, trackingState: .normal), "0.49 s later")
        XCTAssertTrue(gate.admit(transform: turned11, timestamp: 1.8, trackingState: .normal), "0.5 s later")
        XCTAssertFalse(gate.admit(transform: turned11, timestamp: 5, trackingState: .limitedExcessiveMotion), "never when not normal")
    }
}
