import Foundation
import simd
import XCTest
@testable import LieDAR

/// Compiles only if the payload types are really `Sendable`: the values cross a detached task
/// and an actor boundary under Swift 6 strict concurrency, which is a compile-time proof (RT-3).
final class SendableTests: XCTestCase {

    private actor Sink {
        private(set) var frames: [FramePayload] = []
        private(set) var anchors: [MeshAnchorPayload] = []
        func take(_ frame: FramePayload) { frames.append(frame) }
        func take(_ anchor: MeshAnchorPayload) { anchors.append(anchor) }
    }

    func testFramePayloadCrossesATaskBoundaryIntact() async throws {
        let frame = Golden.frame(index: 4, color: try Golden.redBGRA())
        let widthOnAnotherTask = await Task.detached { frame.depth.width * frame.depth.height }.value
        XCTAssertEqual(widthOnAnotherTask, 12)

        let sink = Sink()
        await sink.take(frame)
        let stored = await sink.frames
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0].meta, Golden.meta(index: 4))
        XCTAssertEqual(stored[0].depth.values(), Golden.depthValues)
        XCTAssertEqual(stored[0].confidence?.values(), Golden.confidenceValues)
        XCTAssertEqual(stored[0].color?.pixelFormat, .bgra32)
    }

    func testMeshAnchorPayloadAndEventsCrossATaskBoundary() async {
        let anchor = Golden.quadAnchor()
        let event = AnchorEvent.added(anchor)
        let id = await Task.detached { event.anchorID }.value
        XCTAssertEqual(id, Golden.anchorID)

        let sink = Sink()
        await sink.take(anchor)
        let stored = await sink.anchors
        XCTAssertEqual(stored, [anchor])
        XCTAssertEqual(stored[0].transform.translation, SIMD3(10, 0, 0))
    }

    func testCameraSampleCarriesASendableMaterializer() async {
        let sample = CameraSample(transform: matrix_identity_float4x4, timestamp: 1, trackingState: .limitedInitializing) {
            Golden.frame(index: 0)
        }
        let index = await Task.detached { sample.materialize()?.meta.index }.value
        XCTAssertEqual(index, 0)
        XCTAssertFalse(sample.trackingState.isNormal)
    }

    func testRecorderIsUsableFromAnotherTask() async throws {
        let folder = try makeScratchDirectory()
        let recorder = try CaptureRecorder(folderURL: folder, options: .init(saveColorImages: false))
        let accepted = await Task.detached { recorder.write(Golden.frame(index: 0)) }.value
        XCTAssertTrue(accepted)
        try await recorder.finish(manifest: Golden.manifest(frameCount: 1, summary: .init()))
        XCTAssertEqual(CaptureReader(folderURL: folder).completeFrameIndices(), [0])
    }

    func testNullCaptureSourceIsInertAndStreamsFinish() async throws {
        let source: any CaptureSource = NullCaptureSource()
        XCTAssertFalse(source.isAvailable)
        XCTAssertTrue(source.cameraAuthorized)
        try source.start()
        var sampleCount = 0
        for await _ in source.samples { sampleCount += 1 }
        var eventCount = 0
        for await _ in source.anchorEvents { eventCount += 1 }
        XCTAssertEqual(sampleCount, 0)
        XCTAssertEqual(eventCount, 0)
        XCTAssertEqual(source.meshSnapshot().count, 0)
        XCTAssertNil(source.raycast(screenPoint: CGPoint(x: 1, y: 1)))
        XCTAssertTrue(source.makeCaptureView() is NullCaptureView)
        source.stop()
    }
}
