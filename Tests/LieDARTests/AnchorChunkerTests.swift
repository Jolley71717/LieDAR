import Foundation
import simd
import XCTest
@testable import LieDAR

/// The chunker's anchor set for the canonical room and the canonical tour, asserted by count
/// and bounds; overlap, churn and loop closure each by their observable effect.
final class AnchorChunkerTests: XCTestCase {
    let room = RoomModel.parametric(.canonical)

    /// Feeds every tick of the canonical tour through a coarse render, as the source does.
    private func runTour(_ chunker: AnchorChunker, seconds: TimeInterval = 8.5) -> [AnchorEvent] {
        let raycaster = Raycaster(model: room)
        let camera = VirtualCamera(path: .tour(of: .canonical, seconds: seconds))
        var events: [AnchorEvent] = []
        for tick in camera.ticks() {
            let frame = raycaster.render(cameraToWorld: tick.cameraToWorld, intrinsics: .iPhonePro, resolution: PixelSize(width: 64, height: 48))
            events += chunker.observe(triangleIDs: frame.triangleIDs)
        }
        return events
    }

    func testGridCoversTheRoomInMetreBlocks() {
        let chunker = AnchorChunker(model: room)
        // 5 × 4 × 2.4 m at 1 m cells shifted by 0.5 m with a 0.1 m margin: x 0…5 → cells 0…5
        // (6), y 0…2.4 → 0…2 (3), z 0…4 → 0…4 (5); interior cells with no surface near them
        // (the middle of the room at y = 1) are absent.
        XCTAssertEqual(chunker.blockCount, 110)
        XCTAssertEqual(chunker.discoveredCount, 0)
    }

    func testTourDiscoversAnchorsByCountAndBounds() {
        let chunker = AnchorChunker(model: room, configuration: .init(seed: 3))
        let events = runTour(chunker)
        let anchors = chunker.anchors()
        XCTAssertEqual(anchors.count, 83, "anchors discovered by the 8.5 s canonical tour")
        XCTAssertEqual(chunker.discoveredCount, anchors.count)
        let added = events.filter { if case .added = $0 { return true } else { return false } }.count
        let updated = events.filter { if case .updated = $0 { return true } else { return false } }.count
        let removed = events.filter { if case .removed = $0 { return true } else { return false } }.count
        XCTAssertEqual(added, anchors.count + removed, "every anchor was added once, plus once more per churn")
        XCTAssertEqual(removed, 10, "seeded churn count")
        XCTAssertEqual(updated, 98, "seeded update count")

        // Every anchor's world-space vertices lie within the room (plus the overlap margin),
        // and every anchor has at least the discovery threshold of faces.
        let totalFaces = anchors.reduce(0) { $0 + $1.faceCount }
        for anchor in anchors {
            XCTAssertGreaterThanOrEqual(anchor.faceCount, 4)
            XCTAssertNoThrow(try anchor.validate())
            for v in anchor.vertexArray() {
                let w = anchor.transform.transformPoint(v)
                XCTAssertGreaterThanOrEqual(w.x, -1e-4); XCTAssertLessThanOrEqual(w.x, 5 + 1e-4)
                XCTAssertGreaterThanOrEqual(w.y, -1e-4); XCTAssertLessThanOrEqual(w.y, 2.4 + 1e-4)
                XCTAssertGreaterThanOrEqual(w.z, -1e-4); XCTAssertLessThanOrEqual(w.z, 4 + 1e-4)
            }
            // The anchor origin is its block's corner: on the metre grid shifted by half a cell.
            let origin = anchor.transform.translation + 0.5
            XCTAssertEqual(origin.x, origin.x.rounded(), accuracy: 1e-5)
            XCTAssertEqual(origin.z, origin.z.rounded(), accuracy: 1e-5)
        }
        XCTAssertEqual(totalFaces, 1754, "faces over all anchors, duplicates included")
        XCTAssertGreaterThan(totalFaces, chunker.seenTriangleCount, "overlap duplicates triangles across neighbours")
        XCTAssertEqual(chunker.seenTriangleCount, 490, "distinct room triangles the tour saw of \(room.triangleCount)")
    }

    func testOverlapPutsBoundaryTrianglesInTwoBlocks() {
        let chunker = AnchorChunker(model: room)
        _ = runTour(chunker)
        // Collect world-space triangles per anchor and look for one present in two anchors.
        var owners: [String: Int] = [:]
        for anchor in chunker.anchors() {
            let vertices = anchor.vertexArray().map { anchor.transform.transformPoint($0) }
            for face in anchor.faceArray() {
                let key = [vertices[Int(face.x)], vertices[Int(face.y)], vertices[Int(face.z)]]
                    .map { "\($0.x),\($0.y),\($0.z)" }.joined(separator: "|")
                owners[key, default: 0] += 1
            }
        }
        let shared = owners.values.filter { $0 > 1 }.count
        XCTAssertGreaterThan(shared, 100, "\(shared) triangles appear in more than one anchor")
    }

    func testChurnReplacesAnAnchorUnderANewUUID() {
        let chunker = AnchorChunker(model: room, configuration: .init(churnProbability: 1.0, seed: 11))
        let events = runTour(chunker, seconds: 4)
        var live: Set<UUID> = []
        var removedThenAdded = 0
        var previous: AnchorEvent?
        for event in events {
            switch event {
            case .added(let a):
                XCTAssertFalse(live.contains(a.id), "a re-added anchor carries a NEW id")
                live.insert(a.id)
                if case .removed(let old)? = previous { XCTAssertNotEqual(old, a.id); removedThenAdded += 1 }
            case .removed(let id):
                XCTAssertTrue(live.remove(id) != nil, "removed an anchor that was live")
            case .updated:
                XCTFail("with churn at 1.0 every update is a remove + add")
            }
            previous = event
        }
        XCTAssertGreaterThan(removedThenAdded, 5)
        XCTAssertEqual(Set(chunker.anchors().map(\.id)), live)
        XCTAssertEqual(Set(chunker.anchors().map(\.id)).count, chunker.anchors().count, "ids are unique")
    }

    func testUUIDsAreSeeded() {
        let a = AnchorChunker(model: room, configuration: .init(seed: 5)), b = AnchorChunker(model: room, configuration: .init(seed: 5))
        _ = runTour(a, seconds: 4); _ = runTour(b, seconds: 4)
        XCTAssertEqual(a.anchors().map(\.id), b.anchors().map(\.id))
        XCTAssertEqual(a.anchors(), b.anchors())
        let c = AnchorChunker(model: room, configuration: .init(seed: 6))
        _ = runTour(c, seconds: 4)
        XCTAssertNotEqual(a.anchors().map(\.id), c.anchors().map(\.id))
    }

    func testLoopClosureTranslatesEveryAnchorAtOnce() {
        let chunker = AnchorChunker(model: room)
        _ = runTour(chunker, seconds: 4)
        let before = chunker.anchors()
        XCTAssertGreaterThan(before.count, 10)
        let delta = SIMD3<Float>(0.03, 0.01, -0.02)
        let events = chunker.applyLoopClosure(translation: delta)
        XCTAssertEqual(events.count, before.count, "loop closure re-emits every anchor")
        let after = chunker.anchors()
        for (old, new) in zip(before, after) {
            XCTAssertEqual(new.id, old.id)
            XCTAssertEqual(new.vertices, old.vertices, "geometry is untouched; only the transform moves")
            let moved = new.transform.translation - old.transform.translation
            XCTAssertEqual(moved.x, delta.x, accuracy: 1e-6, "loop closure translation x")
            XCTAssertEqual(moved.y, delta.y, accuracy: 1e-6, "loop closure translation y")
            XCTAssertEqual(moved.z, delta.z, accuracy: 1e-6, "loop closure translation z")
        }
        for case .updated(let a) in events {
            XCTAssertNotNil(after.first { $0.id == a.id && $0.transform == a.transform })
        }
    }
}
