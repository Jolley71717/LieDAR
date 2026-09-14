#if canImport(ARKit) && os(iOS) && !targetEnvironment(macCatalyst)
import ARKit
import AVFoundation
import CoreVideo
import Foundation
import RealityKit
import XCTest
import simd
@testable import LieDAR
@testable import LieDARARKit

/// What can honestly be asserted about `ARKitCaptureSource` without a phone.
///
/// ARKit delivers no frames on a Simulator, and `ARFrame`, `ARMeshAnchor` and `ARMeshGeometry`
/// have no public initialisers, so no test anywhere can hand this type one. Everything below is
/// something a Simulator can actually decide: the availability gate, the camera gate, the
/// lifecycle of the streams, the tracking-state mapping, and the pixel-buffer reads, which use
/// buffers this test creates. `docs/ARKIT_SOURCE.md` lists what is left for a device.
final class ARKitCaptureSourceTests: XCTestCase {

    // MARK: Availability (RT-1)

    func testAvailabilityIsTheSceneReconstructionQueryAndNothingElse() {
        let source = ARKitCaptureSource()
        let expected = ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
            && ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        XCTAssertEqual(source.isAvailable, expected, "isAvailable is the hardware query, asked of the source")
    }

    func testUnclassifiedMeshIsAskedForSeparately() {
        let source = ARKitCaptureSource(configuration: .init(classifiesMesh: false))
        let expected = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
            && ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        XCTAssertEqual(source.isAvailable, expected, "a source that does not classify asks about plain mesh")
    }

    func testSimulatorReportsUnavailableAndRefusesToStart() throws {
        #if targetEnvironment(simulator)
        let source = ARKitCaptureSource()
        XCTAssertFalse(source.isAvailable, "scene reconstruction is unavailable on a Simulator")
        XCTAssertThrowsError(try source.start(), "start on a Simulator") { error in
            XCTAssertEqual(error as? CaptureSourceError, .unavailable,
                           "start refuses where the hardware cannot reconstruct a scene")
        }
        #else
        throw XCTSkip("this asserts the Simulator's answer; on a device isAvailable is the device's own")
        #endif
    }

    func testCameraAuthorizationIsReadFromTheSystem() {
        let source = ARKitCaptureSource()
        let expected = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        XCTAssertEqual(source.cameraAuthorized, expected, "cameraAuthorized follows the video authorization status")
    }

    // MARK: Lifecycle

    func testStreamsAreFinishedBeforeStartAndAfterStop() async {
        let source = ARKitCaptureSource()

        var before = 0
        for await _ in source.samples { before += 1 }
        XCTAssertEqual(before, 0, "samples before start: expected a finished stream")

        source.stop()

        var samples = 0
        for await _ in source.samples { samples += 1 }
        XCTAssertEqual(samples, 0, "samples after stop: expected a finished stream")

        var anchors = 0
        for await _ in source.anchorEvents { anchors += 1 }
        XCTAssertEqual(anchors, 0, "anchor events after stop: expected a finished stream")

        var events = 0
        for await _ in source.sessionEvents { events += 1 }
        XCTAssertEqual(events, 0, "session events after stop: expected a finished stream")
    }

    func testAFreshSourceHoldsNoMeshAndNoWorldMap() async {
        let source = ARKitCaptureSource()
        XCTAssertEqual(source.meshSnapshot().count, 0, "a source that never ran holds no anchors")
        let map = await source.worldMapData()
        XCTAssertNil(map, "a session that never ran has no world map to archive")
    }

    func testRaycastAnswersNilBeforeThereIsAViewToHit() {
        let source = ARKitCaptureSource()
        XCTAssertNil(source.raycast(screenPoint: CGPoint(x: 100, y: 100)),
                     "no capture view means no screen point to raycast from")
    }

    @MainActor
    func testCaptureViewIsMadeOnceAndBoundToTheSourcesSession() {
        let source = ARKitCaptureSource()
        let first = source.makeCaptureView()
        let second = source.makeCaptureView()
        XCTAssertTrue(first === second, "the source keeps the view it made")

        let view = first as? ARView
        XCTAssertNotNil(view, "the capture view is a RealityKit ARView")
        XCTAssertEqual(view?.automaticallyConfigureSession, false,
                       "start() configures the session, not the view")
    }

    func testTheSourceIsUsableThroughTheProtocolAlone() {
        let source: any CaptureSource = ARKitCaptureSource()
        XCTAssertEqual(source.meshSnapshot().count, 0)
        XCTAssertFalse(source.isAvailable && !source.cameraAuthorized,
                       "a source reporting available must also have said something about the camera")
    }

    // MARK: Tracking state

    func testEveryARKitTrackingStateMapsToTheOnDiskString() {
        let cases: [(ARCamera.TrackingState, TrackingState, String)] = [
            (.normal, .normal, "normal"),
            (.notAvailable, .notAvailable, "notAvailable"),
            (.limited(.initializing), .limitedInitializing, "limited.initializing"),
            (.limited(.excessiveMotion), .limitedExcessiveMotion, "limited.excessiveMotion"),
            (.limited(.insufficientFeatures), .limitedInsufficientFeatures, "limited.insufficientFeatures"),
            (.limited(.relocalizing), .limitedRelocalizing, "limited.relocalizing"),
        ]
        for (arkit, expected, raw) in cases {
            XCTAssertEqual(TrackingState(arkit), expected, "tracking state for \(raw)")
            XCTAssertEqual(TrackingState(arkit).rawValue, raw, "on-disk string for \(raw)")
        }
        XCTAssertTrue(TrackingState(ARCamera.TrackingState.normal).isNormal, "only normal frames are written")
        XCTAssertFalse(TrackingState(ARCamera.TrackingState.limited(.relocalizing)).isNormal,
                       "a relocalizing frame is not written")
    }

    // MARK: Pixel buffers

    /// A pixel buffer of `format`, with every plane's bytes filled by `fill`.
    private func makeBuffer(width: Int, height: Int, format: OSType,
                            fill: (UnsafeMutableRawPointer, Int, Int, Int) -> Void) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attributes as CFDictionary, &created)
        let buffer = try XCTUnwrap(created, "CVPixelBufferCreate returned \(status)")
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        if CVPixelBufferIsPlanar(buffer) {
            for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
                let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
                fill(base, plane, CVPixelBufferGetBytesPerRowOfPlane(buffer, plane), CVPixelBufferGetHeightOfPlane(buffer, plane))
            }
        } else {
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
            fill(base, 0, CVPixelBufferGetBytesPerRow(buffer), height)
        }
        return buffer
    }

    func testDepthBufferIsCopiedIntoAPackedFloatPlane() throws {
        let width = 8, height = 4
        let buffer = try makeBuffer(width: width, height: height, format: kCVPixelFormatType_DepthFloat32) { base, _, bytesPerRow, rows in
            for y in 0..<rows {
                let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float32.self)
                for x in 0..<width { row[x] = Float32(y * width + x) / 10 }
            }
        }
        let plane: Plane<Float32> = try ARKitCaptureSource.plane(of: buffer, as: Float32.self)
        XCTAssertEqual(plane.width, width, "depth plane width")
        XCTAssertEqual(plane.height, height, "depth plane height")
        XCTAssertTrue(plane.isTightlyPacked, "the copy drops the buffer's row padding")
        XCTAssertEqual(plane[0, 0], 0, "depth pixel (0, 0)")
        XCTAssertEqual(plane[7, 3], 3.1, accuracy: 1e-6, "depth pixel (7, 3)")
        XCTAssertEqual(plane.values().count, width * height, "one depth value per pixel")
    }

    func testConfidenceBufferIsCopiedIntoAPackedBytePlane() throws {
        let width = 8, height = 4
        let buffer = try makeBuffer(width: width, height: height, format: kCVPixelFormatType_OneComponent8) { base, _, bytesPerRow, rows in
            for y in 0..<rows {
                let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width { row[x] = UInt8((x + y) % 3) }
            }
        }
        let plane: Plane<UInt8> = try ARKitCaptureSource.plane(of: buffer, as: UInt8.self)
        XCTAssertEqual(plane.values().prefix(8).map { $0 }, [0, 1, 2, 0, 1, 2, 0, 1], "the first confidence row")
        XCTAssertEqual(plane[7, 3], 1, "confidence pixel (7, 3)")
    }

    func testBiPlanarCameraImageBecomesTwoPlanesTheFormatAccepts() throws {
        let width = 8, height = 4
        let buffer = try makeBuffer(width: width, height: height,
                                    format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) { base, plane, bytesPerRow, rows in
            // Both planes hold `width` bytes per row here: luma is one byte per pixel, and
            // chroma is width/2 Cb,Cr pairs of two bytes each.
            let bytes = width
            for y in 0..<rows {
                let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                for x in 0..<bytes { row[x] = UInt8((plane == 0 ? 1 : 100) + y * 10 + x) }
            }
        }
        let planes = try ARKitCaptureSource.colorPlanes(of: buffer)
        XCTAssertEqual(planes.pixelFormat, .yCbCr420BiPlanarFullRange, "ARKit's camera image format")
        XCTAssertEqual(planes.width, width, "colour width")
        XCTAssertEqual(planes.height, height, "colour height")
        XCTAssertEqual(planes.planes.count, 2, "luma then interleaved chroma")
        XCTAssertEqual(planes.planes[0].width, 8, "luma plane is one byte per pixel")
        XCTAssertEqual(planes.planes[0].bytesPerRow, 8, "luma rows are packed")
        XCTAssertEqual(planes.planes[1].width, 4, "the chroma plane's width counts Cb,Cr pairs")
        XCTAssertEqual(planes.planes[1].bytesPerRow, 8, "a chroma row is two bytes per pair")
        XCTAssertEqual(planes.planes[0][0, 0], 1, "luma pixel (0, 0)")
        XCTAssertEqual(Array(planes.planes[1].data.prefix(4)), [100, 101, 102, 103], "the first chroma row's bytes")
    }

    func testBGRACameraImageBecomesOnePlane() throws {
        let width = 4, height = 2
        let buffer = try makeBuffer(width: width, height: height, format: kCVPixelFormatType_32BGRA) { base, _, bytesPerRow, rows in
            for y in 0..<rows {
                let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                for x in 0..<(width * 4) { row[x] = UInt8(x % 256) }
            }
        }
        let planes = try ARKitCaptureSource.colorPlanes(of: buffer)
        XCTAssertEqual(planes.pixelFormat, .bgra32, "a BGRA camera image")
        XCTAssertEqual(planes.planes.count, 1, "BGRA is one plane")
        XCTAssertEqual(planes.planes[0].bytesPerRow, width * 4, "four bytes per pixel, packed")
    }

    func testAColourFormatTheCaptureFormatHasNoPlaceForIsRefused() throws {
        let buffer = try makeBuffer(width: 4, height: 2, format: kCVPixelFormatType_16Gray) { _, _, _, _ in }
        XCTAssertThrowsError(try ARKitCaptureSource.colorPlanes(of: buffer), "16-bit grey camera image") { error in
            XCTAssertEqual(error as? ARKitCaptureSource.ReadError,
                           .unsupportedColorFormat(kCVPixelFormatType_16Gray),
                           "an unknown colour format is refused by name, not copied as something else")
        }
    }
}
#endif
