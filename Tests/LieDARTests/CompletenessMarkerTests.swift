import Foundation
import XCTest
@testable import LieDAR

/// A frame is complete exactly when its `.json` exists, because the recorder writes it last.
/// These tests remove or prevent that file and check the reader says so.
final class CompletenessMarkerTests: XCTestCase {

    func testAFrameWhoseJSONIsMissingIsReportedIncomplete() async throws {
        let folder = try makeScratchDirectory()
        let recorder = try CaptureRecorder(folderURL: folder, options: .init(saveColorImages: false))
        for index in 0..<3 { XCTAssertTrue(recorder.write(Golden.frame(index: index))) }
        try await recorder.finish(manifest: Golden.manifest(frameCount: 3, summary: .init()))

        try FileManager.default.removeItem(at: folder.appendingPathComponent("frames/000001.json"))

        let reader = CaptureReader(folderURL: folder)
        XCTAssertEqual(reader.completeFrameIndices(), [0, 2])
        XCTAssertEqual(reader.incompleteFrameIndices(), [1])
        XCTAssertEqual(reader.frameStatuses()[1],
                       CaptureReader.FrameStatus(index: 1, hasDepth: true, hasConfidence: true, hasColor: false, hasMeta: false))
        XCTAssertFalse(reader.frameStatuses()[1].isComplete)
        XCTAssertThrowsError(try reader.frameMeta(1)) { XCTAssertEqual($0 as? CaptureReader.ReadError, .frameIncomplete(1)) }
        XCTAssertThrowsError(try reader.depth(1)) { XCTAssertEqual($0 as? CaptureReader.ReadError, .frameIncomplete(1)) }
        XCTAssertEqual(CaptureFormat.contents(of: folder).frameCount, 2, "the folder count follows the marker, not the binaries")
        XCTAssertEqual(try reader.manifest().frameCount, 3, "the manifest still says 3: it counts accepted frames, the disk is the truth")
    }

    func testAFrameWhoseBinaryWriteFailedLeavesNoJSONAndIsReportedAsAFailure() async throws {
        let folder = try makeScratchDirectory()
        let recorder = try CaptureRecorder(folderURL: folder, options: .init(saveColorImages: false))
        // Pull the frames directory out from under the writer: the depth write fails, so the
        // JSON, which comes after it, must never be written.
        try FileManager.default.removeItem(at: folder.appendingPathComponent("frames"))
        XCTAssertTrue(recorder.write(Golden.frame(index: 0)), "accepted: the failure happens on the queue")
        try await recorder.finish(manifest: Golden.manifest(frameCount: 1, summary: .init()))

        let failure = try XCTUnwrap(recorder.frameWriteFailure)
        XCTAssertEqual(failure.count, 1)
        XCTAssertTrue(failure.message.hasPrefix("frame 0: "), failure.message)
        XCTAssertEqual(CaptureFormat.contents(of: folder).frameCount, 0)
        XCTAssertEqual(CaptureReader(folderURL: folder).frameStatuses(), [])
        XCTAssertEqual(CaptureFormat.disposition(of: CaptureFormat.contents(of: folder)), .discardEmpty)
    }

    /// Guards the write ORDER, not just the failure path: only the depth write can fail here (a
    /// directory squats on its path), so a recorder that wrote the `.json` first would leave a
    /// marker for a frame with no depth. The other failure test removes `frames/` outright, which
    /// fails every write regardless of order and cannot tell the two apart.
    func testJSONIsNotWrittenWhenOnlyTheDepthWriteFails() async throws {
        let folder = try makeScratchDirectory()
        let recorder = try CaptureRecorder(folderURL: folder, options: .init(saveColorImages: false))
        let depthURL = folder.appendingPathComponent("frames/000000.depth")
        try FileManager.default.createDirectory(at: depthURL, withIntermediateDirectories: false)

        XCTAssertTrue(recorder.write(Golden.frame(index: 0)))
        try await recorder.finish(manifest: Golden.manifest(frameCount: 1, summary: .init()))

        let jsonURL = folder.appendingPathComponent("frames/000000.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: jsonURL.path),
                       "the .json must be written after the depth, so a failed depth write leaves no marker")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("frames/000000.conf").path),
                       "confidence comes after depth too")
        XCTAssertEqual(CaptureReader(folderURL: folder).completeFrameIndices(), [])
        XCTAssertEqual(recorder.frameWriteFailure?.count, 1)
        XCTAssertTrue(recorder.frameWriteFailure?.message.hasPrefix("frame 0: ") ?? false)
    }

    func testAnUnfinishedFolderHasNoManifest() throws {
        let folder = try makeScratchDirectory()
        _ = try CaptureRecorder(folderURL: folder)
        let reader = CaptureReader(folderURL: folder)
        XCTAssertFalse(reader.isFinished)
        XCTAssertThrowsError(try reader.manifest()) {
            guard case .missingManifest? = $0 as? CaptureReader.ReadError else { return XCTFail("\($0)") }
        }
        XCTAssertTrue(reader.contents.isEmpty)
    }

    func testDispositionFollowsWhatIsOnDisk() {
        XCTAssertEqual(CaptureFormat.disposition(of: CaptureContents(frameCount: 0, meshAnchorCount: 0)), .discardEmpty)
        XCTAssertEqual(CaptureFormat.disposition(of: CaptureContents(frameCount: 12, meshAnchorCount: 0)), .keepWithoutMesh)
        XCTAssertEqual(CaptureFormat.disposition(of: CaptureContents(frameCount: 0, meshAnchorCount: 3)), .keep)
        XCTAssertEqual(CaptureFormat.disposition(of: CaptureContents(frameCount: 40, meshAnchorCount: 9)), .keep)
        XCTAssertEqual(CaptureFormat.contents(of: URL(fileURLWithPath: "/nonexistent/LieDAR")), CaptureContents())
    }
}
