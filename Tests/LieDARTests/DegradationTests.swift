import Foundation
import simd
import XCTest
@testable import LieDAR
import LieDARSynthetic

final class DegradationTests: XCTestCase {
    let room = RoomModel.parametric(.canonical)

    /// The whole canonical room as one anchor: 842 faces, none of them unlabelled.
    private func wholeRoomAnchor(id: UUID = UUID(uuidString: "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9")!) -> MeshAnchorPayload {
        let vertices = room.vertices.flatMap { [$0.x, $0.y, $0.z] }
        let faces = room.triangles.flatMap { [$0.x, $0.y, $0.z] }
        return MeshAnchorPayload(id: id, transform: matrix_identity_float4x4, vertices: vertices, faces: faces,
                                 classes: room.classes.map(\.rawValue))
    }

    func testUnlabelledFractionMatchesTheModelForASeed() {
        let anchor = wholeRoomAnchor()
        let degraded = DegradationModel(seed: 42).apply(to: anchor)
        let classes = degraded.classArray()
        let none = classes.filter { $0 == 0 }.count
        let fraction = Double(none) / Double(classes.count)
        XCTAssertEqual(classes.count, 842)
        XCTAssertEqual(fraction, 0.30, accuracy: 0.03, "unlabelled fraction for seed 42 is \(fraction) (\(none) of \(classes.count))")
        XCTAssertEqual(degraded.vertices, anchor.vertices, "geometry untouched")
        XCTAssertEqual(degraded.faces, anchor.faces)
        XCTAssertEqual(degraded.id, anchor.id)
        // The exact count is pinned too: the model is seeded, so it cannot drift silently.
        XCTAssertEqual(none, 259, "exact unlabelled count for seed 42")
    }

    func testFloorAndTableAreConfusedAtASmallRate() {
        let anchor = wholeRoomAnchor()
        // Isolate the confusion: no unlabelled faces, no noise.
        let model = DegradationModel(seed: 9, unlabelledFraction: 0, floorTableConfusion: 0.1, labelNoise: 0)
        let classes = model.apply(to: anchor).classArray()
        var floorToTable = 0, tableToFloor = 0, otherChanges = 0
        for (original, degraded) in zip(room.classes, classes) where original.rawValue != degraded {
            switch (original, degraded) {
            case (.floor, 4): floorToTable += 1
            case (.table, 2): tableToFloor += 1
            default: otherChanges += 1
            }
        }
        XCTAssertEqual(otherChanges, 0, "only floor↔table changes")
        XCTAssertEqual(Double(floorToTable) / 160, 0.1, accuracy: 0.06, "\(floorToTable) of 160 floor faces became table")
        XCTAssertGreaterThan(tableToFloor, 0, "\(tableToFloor) of 52 table faces became floor")
    }

    func testPerAnchorNoiseVariesBetweenAnchorsAndIsSeeded() {
        let model = DegradationModel(seed: 1, unlabelledFraction: 0, floorTableConfusion: 0, labelNoise: 0.5)
        var rates: Set<Int> = []
        for i in 0..<6 {
            var rng = SeededRandom(seed: UInt64(i))
            let anchor = wholeRoomAnchor(id: rng.nextUUID())
            let classes = model.apply(to: anchor).classArray()
            let changed = zip(room.classes, classes).filter { $0.0.rawValue != $0.1 }.count
            rates.insert(changed)
            XCTAssertEqual(model.apply(to: anchor).classArray(), classes, "same anchor, same seed, same result")
        }
        XCTAssertGreaterThan(rates.count, 3, "different anchors draw different noise rates: \(rates.sorted())")
    }

    func testIdentityModelChangesNothing() {
        let anchor = wholeRoomAnchor()
        XCTAssertEqual(DegradationModel.none.apply(to: anchor), anchor)
    }

    func testSeededRandomIsStableAcrossRuns() {
        // SplitMix64 reference values for seed 0 (first two outputs), so the stream can never
        // change without this test noticing.
        var rng = SeededRandom(seed: 0)
        XCTAssertEqual(rng.next(), 0xE220_A839_7B1D_CDAF)
        XCTAssertEqual(rng.next(), 0x6E78_9E6A_A1B9_65F4)
        var a = SeededRandom(seed: 7, label: 1), b = SeededRandom(seed: 7, label: 1), c = SeededRandom(seed: 7, label: 2)
        XCTAssertEqual(a.nextUUID(), b.nextUUID())
        XCTAssertNotEqual(a.nextUUID(), c.nextUUID())
        var d = SeededRandom(seed: 3)
        for _ in 0..<1000 {
            let x = d.nextDouble()
            XCTAssertTrue(x >= 0 && x < 1)
            XCTAssertTrue((0..<5).contains(d.nextInt(below: 5)))
        }
    }
}
