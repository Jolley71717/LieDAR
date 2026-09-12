import Foundation
import XCTest
@testable import LieDAR

/// The recorder's backpressure rule: while `maxPendingFrames` frames are queued, further frames
/// are dropped, `write` says so, and the drop count is exact.
final class BackpressureTests: XCTestCase {

    func testFramesOfferedOverTheCapAreDroppedAndCounted() async throws {
        let folder = try makeScratchDirectory()
        let recorder = try CaptureRecorder(folderURL: folder, options: .init(saveColorImages: false, maxPendingFrames: 3))

        // Hold the writer queue so nothing drains.
        let gate = DispatchSemaphore(value: 0)
        recorder.enqueue { gate.wait() }

        var results: [Bool] = []
        for index in 0..<8 {
            results.append(recorder.write(Golden.frame(index: index)))
        }
        XCTAssertEqual(results, [true, true, true, false, false, false, false, false])
        XCTAssertEqual(recorder.acceptedFrameCount, 3)
        XCTAssertEqual(recorder.pendingFrameCount, 3)
        XCTAssertEqual(recorder.droppedFrameCount, 5, "exactly the five frames past the cap")
        XCTAssertEqual(CaptureFormat.contents(of: folder).frameCount, 0, "nothing reaches the disk while the queue is held")

        gate.signal()
        try await recorder.finish(manifest: Golden.manifest(frameCount: 3, summary: .init()))

        XCTAssertEqual(recorder.pendingFrameCount, 0)
        XCTAssertEqual(CaptureReader(folderURL: folder).completeFrameIndices(), [0, 1, 2])
        XCTAssertEqual(CaptureFormat.contents(of: folder).frameCount, 3)
        XCTAssertNil(recorder.frameWriteFailure)
    }

    func testTheCapReopensOnceTheQueueDrains() async throws {
        let folder = try makeScratchDirectory()
        let recorder = try CaptureRecorder(folderURL: folder, options: .init(saveColorImages: false, maxPendingFrames: 2))

        let gate = DispatchSemaphore(value: 0)
        recorder.enqueue { gate.wait() }
        XCTAssertTrue(recorder.write(Golden.frame(index: 0)))
        XCTAssertTrue(recorder.write(Golden.frame(index: 1)))
        XCTAssertFalse(recorder.write(Golden.frame(index: 2)))
        gate.signal()

        // Wait for the two accepted frames to land, then the third attempt is accepted.
        let drained = expectation(description: "queue drained")
        recorder.enqueue { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 10)
        XCTAssertEqual(recorder.pendingFrameCount, 0)
        XCTAssertTrue(recorder.write(Golden.frame(index: 2)))

        try await recorder.finish(manifest: Golden.manifest(frameCount: 3, summary: .init()))
        XCTAssertEqual(recorder.droppedFrameCount, 1)
        XCTAssertEqual(recorder.acceptedFrameCount, 3)
        XCTAssertEqual(CaptureReader(folderURL: folder).completeFrameIndices(), [0, 1, 2])
    }

    func testWritesAfterFinishAreDroppedAndASecondFinishThrows() async throws {
        let folder = try makeScratchDirectory()
        let recorder = try CaptureRecorder(folderURL: folder, options: .init(saveColorImages: false))
        XCTAssertTrue(recorder.write(Golden.frame(index: 0)))
        try await recorder.finish(manifest: Golden.manifest(frameCount: 1, summary: .init()))

        XCTAssertFalse(recorder.write(Golden.frame(index: 1)))
        XCTAssertEqual(recorder.droppedFrameCount, 1)
        do {
            try await recorder.finish(manifest: Golden.manifest(frameCount: 1, summary: .init()))
            XCTFail("second finish must throw")
        } catch let error as CaptureRecorder.RecorderError {
            XCTAssertEqual(error, .finished)
        }
        XCTAssertEqual(CaptureReader(folderURL: folder).completeFrameIndices(), [0])
    }

    func testFinishDrainsEveryPendingWriteBeforeTheManifestLands() async throws {
        let folder = try makeScratchDirectory()
        let recorder = try CaptureRecorder(folderURL: folder, options: .init(saveColorImages: false, maxPendingFrames: 50))
        for index in 0..<20 {
            XCTAssertTrue(recorder.write(Golden.frame(index: index)))
        }
        try await recorder.finish(manifest: Golden.manifest(frameCount: 20, summary: .init()))
        let reader = CaptureReader(folderURL: folder)
        XCTAssertTrue(reader.isFinished)
        XCTAssertEqual(reader.completeFrameIndices(), Array(0..<20))
        XCTAssertEqual(reader.incompleteFrameIndices(), [])
        XCTAssertEqual(try reader.manifest().frameCount, 20)
    }
}
