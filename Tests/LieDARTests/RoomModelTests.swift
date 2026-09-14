import Foundation
import simd
import XCTest
@testable import LieDAR
import LieDARSynthetic

final class RoomModelTests: XCTestCase {

    func testCanonicalRoomHasEveryClassItWasBuiltWith() {
        let room = RoomModel.parametric(.canonical)
        let histogram = room.classHistogram()
        XCTAssertEqual(room.triangleCount, 842, "canonical room triangle count is part of the goldens")
        XCTAssertEqual(room.vertices.count, 483, "shared edges are stitched, so far fewer than 842 × 3")
        XCTAssertEqual(histogram[.door], 20, "0.9 × 2.05 m door at 0.5 m cells is 2 × 5 cells, two triangles each")
        XCTAssertEqual(histogram[.window], 12, "1.2 × 0.8 m window at 0.5 m cells is 3 × 2 cells, two triangles each")
        XCTAssertEqual(histogram[.table], 52, "1.2 × 0.7 × 0.75 m table: top 3×2, long sides 3×2 ×2, short sides 2×2 ×2 cells, two triangles each")
        XCTAssertEqual(histogram[.floor], 160, "5 × 4 m floor is 10 × 8 cells, two triangles each")
        XCTAssertEqual(histogram[.ceiling], 160 + 40, "ceiling plus the bulkhead's underside (10 × 2 cells)")
        XCTAssertNil(histogram[.seat])
        XCTAssertNil(histogram[.none], "a parametric room has no unlabelled faces; degradation adds them")
        let bounds = room.bounds
        XCTAssertEqual(bounds.min, SIMD3(0, 0, 0))
        XCTAssertEqual(bounds.max, SIMD3(5, 2.4, 4))
    }

    func testEveryDirectionFromInsideHitsTheRoom() {
        // A closed room has no gaps: six full frames from the middle miss nothing.
        let room = RoomModel.parametric(.canonical)
        let raycaster = Raycaster(model: room)
        let eye = SIMD3<Float>(2.5, 1.2, 2.0)
        let targets: [SIMD3<Float>] = [SIMD3(2.5, 1.2, 0), SIMD3(5, 1.2, 2), SIMD3(2.5, 1.2, 4), SIMD3(0, 1.2, 2),
                                       SIMD3(2.5, 2.4, 2.001), SIMD3(2.5, 0, 2.001)]
        for target in targets {
            let pose = VirtualCamera.lookAt(from: eye, to: target)
            let frame = raycaster.render(cameraToWorld: pose, intrinsics: .iPhonePro, resolution: PixelSize(width: 64, height: 48))
            XCTAssertEqual(frame.hitCount, frame.pixelCount, "looking at \(target) left \(frame.pixelCount - frame.hitCount) gaps")
        }
    }

    func testSeedIsDeterministicAndSeedsDiffer() {
        let a = RoomModel.random(seed: 7), b = RoomModel.random(seed: 7), c = RoomModel.random(seed: 8)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a.triangleCount, c.triangleCount)
        XCTAssertEqual(RoomSpec.random(seed: 7), RoomSpec.random(seed: 7))
    }

    func testLShapeHasSixWallsAndTheNotchIsOutside() {
        let spec = RoomSpec(width: 6, depth: 5, ceilingHeight: 2.4, lCut: .init(cutWidth: 2, cutDepth: 2))
        let walls = RoomModel.wallSegments(of: spec)
        XCTAssertEqual(walls.count, 6)
        XCTAssertEqual(walls.map(\.length), [6, 3, 2, 2, 4, 5])
        XCTAssertFalse(spec.contains(x: 5, z: 4), "inside the notch")
        XCTAssertTrue(spec.contains(x: 3, z: 4))
        let room = RoomModel.parametric(spec)
        // No vertex sits strictly inside the notch (its boundary walls are allowed).
        for v in room.vertices {
            XCTAssertFalse(v.x > 4.0001 && v.z > 3.0001, "vertex \(v) is inside the notch")
        }
        XCTAssertEqual(room.classHistogram()[.floor], (4 * 5 + 2 * 3) * 2 * 4, "two floor rectangles at 0.5 m cells")
    }

    /// A wide sweep, because a narrow one is what let `RoomSpec.random` ship with a trap. The
    /// window offset was drawn from `0.3...(length - 1.5)` while the wall filter admitted 1.6 m,
    /// so a wall between 1.6 and 1.8 m inverted the range and the generator crashed on seeds 36,
    /// 254, 273, 280, 402, 423 and 447. Only the L-cut's short inner faces are ever that short.
    /// Seeds 1 to 12 all survive, which is exactly how far the old sweep went.
    func testRandomRoomsAreClosedForManySeeds() {
        for seed: UInt64 in 1...500 {
            let spec = RoomSpec.random(seed: seed)
            let room = RoomModel.parametric(spec)
            let raycaster = Raycaster(model: room)
            let usable = spec.width - (spec.lCut?.cutWidth ?? 0)
            let eye = SIMD3<Float>(usable / 2, 1.3, spec.depth / 2)
            for target in [SIMD3<Float>(usable / 2, 1.3, 0), SIMD3(0, 1.3, spec.depth / 2), SIMD3(usable / 2, 1.3, spec.depth), SIMD3(usable, 1.3, spec.depth / 2)] {
                let frame = raycaster.render(cameraToWorld: VirtualCamera.lookAt(from: eye, to: target), intrinsics: .iPhonePro,
                                             resolution: PixelSize(width: 32, height: 24))
                XCTAssertEqual(frame.hitCount, frame.pixelCount, "seed \(seed): gaps looking at \(target)")
            }
        }
    }

    // MARK: OBJ

    func testOBJRoundTripsThroughText() throws {
        let room = RoomModel.parametric(.canonical)
        let loaded = try RoomModel(objText: room.objText())
        XCTAssertEqual(loaded.vertices, room.vertices)
        XCTAssertEqual(loaded.triangles.count, room.triangles.count)
        XCTAssertEqual(loaded.classHistogram(), room.classHistogram())
    }

    func testOBJQuadsAndSlashedIndicesAndNames() throws {
        let text = """
        # a quad floor and a wall triangle
        v 0 0 0
        v 1 0 0
        v 1 0 1
        v 0 0 1
        vn 0 1 0
        o Floor_main
        f 1/1/1 2/2/1 3/3/1 4/4/1
        usemtl WallPaint
        f -4 -3 -2
        g nothing_here
        f 1 2 3
        """
        let model = try RoomModel(objText: text)
        XCTAssertEqual(model.vertices.count, 4)
        XCTAssertEqual(model.triangles, [SIMD3(0, 1, 2), SIMD3(0, 2, 3), SIMD3(0, 1, 2), SIMD3(0, 1, 2)])
        XCTAssertEqual(model.classes, [.floor, .floor, .wall, .none])
    }

    func testOBJErrorsAreNamed() {
        XCTAssertThrowsError(try RoomModel(objText: "v 0 0\n")) { XCTAssertEqual($0 as? RoomModel.OBJError, .badVertex(line: 1)) }
        XCTAssertThrowsError(try RoomModel(objText: "v 0 0 0\nf 1 1 9\n")) { XCTAssertEqual($0 as? RoomModel.OBJError, .indexOutOfRange(line: 2, index: 9)) }
        XCTAssertThrowsError(try RoomModel(objText: "v 0 0 0\n")) { XCTAssertEqual($0 as? RoomModel.OBJError, .noTriangles) }
    }
}
