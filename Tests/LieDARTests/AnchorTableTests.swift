import Foundation
import XCTest
import simd
@testable import LieDAR

/// The anchor bookkeeping a live source keeps so `meshSnapshot()` still answers after `stop()`.
final class AnchorTableTests: XCTestCase {

    private func anchor(_ id: UUID, x: Float) -> MeshAnchorPayload {
        MeshAnchorPayload(id: id, transform: simd_float4x4(columns: (SIMD4(1, 0, 0, 0),
                                                                     SIMD4(0, 1, 0, 0),
                                                                     SIMD4(0, 0, 1, 0),
                                                                     SIMD4(x, 0, 0, 1))),
                          vertices: [0, 0, 0, 1, 0, 0, 0, 1, 0], faces: [0, 1, 2], classes: [2])
    }

    func testAddedAnchorsAreHeldAndOrderedByID() {
        var table = AnchorTable()
        XCTAssertTrue(table.isEmpty)
        table.apply(.added(anchor(Golden.secondAnchorID, x: 2)))
        table.apply(.added(anchor(Golden.anchorID, x: 1)))

        XCTAssertEqual(table.count, 2, "held anchor count")
        XCTAssertEqual(table.snapshot().map(\.id), [Golden.anchorID, Golden.secondAnchorID],
                       "snapshot order is by id, not the order they arrived")
    }

    func testUpdateReplacesTheAnchorRatherThanAddingASecond() {
        var table = AnchorTable()
        table.apply(.added(anchor(Golden.anchorID, x: 1)))
        table.apply(.updated(anchor(Golden.anchorID, x: 7)))

        XCTAssertEqual(table.count, 1, "an update of a held anchor leaves one anchor")
        XCTAssertEqual(table.snapshot().first?.transform.translation.x, 7,
                       "the update's geometry replaces what was held")
    }

    func testAddingAnIDAlreadyHeldStillLeavesOneAnchor() {
        var table = AnchorTable()
        table.apply(.added(anchor(Golden.anchorID, x: 1)))
        table.apply(.added(anchor(Golden.anchorID, x: 3)))

        XCTAssertEqual(table.count, 1, "a re-added id leaves one anchor")
        XCTAssertEqual(table[Golden.anchorID]?.transform.translation.x, 3, "the newer payload wins")
    }

    func testRemovedAnchorsLeaveTheTable() {
        var table = AnchorTable()
        table.apply([.added(anchor(Golden.anchorID, x: 1)),
                     .added(anchor(Golden.secondAnchorID, x: 2)),
                     .removed(Golden.anchorID)])

        XCTAssertEqual(table.count, 1, "held anchor count after a removal")
        XCTAssertNil(table[Golden.anchorID], "the removed anchor is gone")
        XCTAssertEqual(table.snapshot().map(\.id), [Golden.secondAnchorID], "only the survivor is in the snapshot")
    }

    func testRemovingSomethingNeverHeldIsHarmless() {
        var table = AnchorTable()
        table.apply(.added(anchor(Golden.anchorID, x: 1)))
        table.apply(.removed(Golden.secondAnchorID))

        XCTAssertEqual(table.count, 1, "removing an unknown id changes nothing")
    }

    func testSnapshotSurvivesTheEventsEndingAndRemoveAllClearsIt() {
        var table = AnchorTable()
        table.apply(.added(anchor(Golden.anchorID, x: 1)))
        let afterStop = table.snapshot()
        XCTAssertEqual(afterStop.count, 1, "the snapshot is the sum of the events, so it stays right after stop")
        XCTAssertEqual(afterStop.first?.faceCount, 1)

        table.removeAll()
        XCTAssertEqual(table.count, 0, "removeAll forgets every anchor")
        XCTAssertEqual(table.snapshot(), [], "an empty table snapshots to nothing")
    }
}
