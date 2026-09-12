import Foundation
import simd
import XCTest
@testable import LieDAR

/// The raycaster is deterministic, so its depth for the canonical room and pose is pinned to
/// the exact bytes in `Goldens/canonical-depth.bin` (256 × 192 × 4 = 196 608 bytes), not to a
/// tolerance. Regenerate the golden — and say so in the commit — only when the raycaster's
/// numerics change on purpose: `LIEDAR_GOLDEN_OUT=Tests/LieDARTests/Goldens swift test --filter
/// RaycasterTests/testDepthMatchesGoldenBytes`.
final class RaycasterTests: XCTestCase {
    static let goldenName = "canonical-depth.bin"

    /// Identity rotation, 3 m in front of the south wall at chest height, facing it: the
    /// canonical pose. Built from constants, not `lookAt`, so no trigonometry is involved.
    static let canonicalPose: simd_float4x4 = {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(2.5, 1.4, 3.0, 1)
        return m
    }()

    let room = RoomModel.parametric(.canonical)

    func testDepthMatchesGoldenBytes() throws {
        let frame = Raycaster(model: room).render(cameraToWorld: Self.canonicalPose, intrinsics: .iPhonePro)
        let bytes = frame.depthBytes()
        XCTAssertEqual(bytes.count, 256 * 192 * 4)

        if let out = ProcessInfo.processInfo.environment["LIEDAR_GOLDEN_OUT"] {
            let url = URL(fileURLWithPath: out).appendingPathComponent(Self.goldenName)
            try bytes.write(to: url)
            throw XCTSkip("wrote golden to \(url.path); re-run without LIEDAR_GOLDEN_OUT")
        }
        guard let goldenURL = Bundle.module.url(forResource: "canonical-depth", withExtension: "bin", subdirectory: "Goldens") else {
            return XCTFail("golden \(Self.goldenName) is missing from the test bundle")
        }
        let golden = try Data(contentsOf: goldenURL)
        XCTAssertEqual(golden.count, bytes.count, "golden size")
        if golden != bytes {
            let first = zip(golden, bytes).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? -1
            let pixel = first / 4
            XCTFail("depth bytes differ from golden; first difference at byte \(first) (pixel \(pixel % 256), \(pixel / 256)): "
                    + "golden \(golden.count > 0 ? String(describing: frame.depth[pixel]) : "?")")
        }
    }

    func testCanonicalDepthHasTheGeometryItShould() {
        let frame = Raycaster(model: room).render(cameraToWorld: Self.canonicalPose, intrinsics: .iPhonePro)
        XCTAssertEqual(frame.hitCount, frame.pixelCount, "a closed room leaves no misses")
        // The pixel nearest the optical axis looks straight at the wall 3 m away.
        let centre = frame.depthAt(x: 128, y: 96)
        XCTAssertEqual(centre, 3.0, accuracy: 1e-5)
        XCTAssertEqual(room.classes[Int(frame.triangleAt(x: 128, y: 96))], .wall)
        // Depth is plane distance, not ray length: every pixel on the wall reads 3 m.
        XCTAssertEqual(frame.depthAt(x: 0, y: 96), 3.0, accuracy: 1e-4, "left edge of the wall row")
        XCTAssertEqual(frame.depthAt(x: 255, y: 96), 3.0, accuracy: 1e-4, "right edge of the wall row")
        // The bottom rows see the floor, which is nearer than the wall (the ray drops 1.4 m).
        let bottom = frame.depthAt(x: 128, y: 191)
        XCTAssertLessThan(bottom, 3.0)
        XCTAssertEqual(room.classes[Int(frame.triangleAt(x: 128, y: 191))], .floor)
        // Row 0 looks up: the ray rises (96 − 0.5)/178.67 = 0.5346 per metre of depth. It would
        // reach the ceiling (2.4 m) at 1.87 m, but the bulkhead (z 1.0…1.6, hanging to 2.05 m) is
        // in the way: its +z side at z = 1.6 is 1.4 m away, where the ray is at y = 2.148.
        XCTAssertEqual(room.classes[Int(frame.triangleAt(x: 128, y: 0))], .wall, "bulkhead side")
        XCTAssertEqual(frame.depthAt(x: 128, y: 0), 1.4, accuracy: 1e-4)
        // The door (x 0.8…1.7 on the south wall, 0…2.05 high) is left of centre at eye height.
        // u for x = 1.25: (1.25 − 2.5) / 3 × fx′ + cx′ = −0.41667 × 178.67 + 128 ≈ 53.6.
        XCTAssertEqual(room.classes[Int(frame.triangleAt(x: 54, y: 96))], .door)
        // The confidence is high on the facing wall and lower on the grazing floor.
        XCTAssertEqual(frame.confidence[96 * 256 + 128], 2)
        XCTAssertEqual(frame.confidence[191 * 256 + 128], 1, "floor seen at cos ≈ 0.47 is grazing: medium")
        XCTAssertEqual(Set(frame.confidence).count > 1, true, "confidence is not uniform")
    }

    func testTwoRendersAreBitIdentical() {
        let a = Raycaster(model: room).render(cameraToWorld: Self.canonicalPose, intrinsics: .iPhonePro)
        let b = Raycaster(model: room).render(cameraToWorld: Self.canonicalPose, intrinsics: .iPhonePro)
        XCTAssertEqual(a, b)
    }

    func testConfidenceFallsOffWithRangeAndGrazingAngle() {
        // A long corridor: 2 m wide, 12 m deep. Looking down it, the far wall is beyond the
        // medium range (low), the side walls are grazing (low or medium), the near floor is high.
        let spec = RoomSpec(width: 2, depth: 12, ceilingHeight: 2.4)
        let raycaster = Raycaster(model: .parametric(spec))
        let pose = VirtualCamera.lookAt(from: SIMD3(1, 1.4, 11.5), to: SIMD3(1, 1.4, 0))
        let frame = raycaster.render(cameraToWorld: pose, intrinsics: .iPhonePro)
        XCTAssertEqual(frame.depthAt(x: 128, y: 96), 11.5, accuracy: 1e-3)
        XCTAssertEqual(frame.confidence[96 * 256 + 128], 0, "far wall beyond 5 m is low")
        XCTAssertEqual(frame.confidence[96 * 256 + 0], 2, "side wall 1.4 m away at cos ≈ 0.58 is high")
        XCTAssertEqual(frame.confidence[191 * 256 + 128], 1, "floor 2.6 m away at cos ≈ 0.47 is medium")
        let histogram = frame.confidence.reduce(into: [UInt8: Int]()) { $0[$1, default: 0] += 1 }
        XCTAssertEqual(histogram.keys.sorted(), [0, 1, 2], "all three confidence levels occur down a corridor")
    }

    func testMissesAreZeroDepthAndMinusOne() {
        // A single floor quad; the camera looks at the horizon so the top half misses.
        let model = RoomModel(vertices: [SIMD3(-5, 0, -5), SIMD3(5, 0, -5), SIMD3(5, 0, 5), SIMD3(-5, 0, 5)],
                              triangles: [SIMD3(0, 1, 2), SIMD3(0, 2, 3)], classes: [.floor, .floor])
        var pose = matrix_identity_float4x4
        pose.columns.3 = SIMD4(0, 1, 0, 1)
        let frame = Raycaster(model: model).render(cameraToWorld: pose, intrinsics: .iPhonePro, resolution: PixelSize(width: 16, height: 12))
        XCTAssertEqual(frame.depthAt(x: 8, y: 0), 0)
        XCTAssertEqual(frame.triangleAt(x: 8, y: 0), -1)
        XCTAssertEqual(frame.confidence[0], 0)
        XCTAssertGreaterThan(frame.depthAt(x: 8, y: 11), 0)
        XCTAssertEqual(frame.hitCount, 16 * 4, "rows 8…11 look down steeply enough to hit the floor within its 5 m; row 7 overshoots")
    }

    // MARK: Timing

    /// PLAN budgets ≤ 20 ms per 256 × 192 frame on an M-series Mac. That is a release-build
    /// figure; the unit suite runs unoptimised, where the same loop is roughly 10× slower, so
    /// the ceiling asserted here depends on the build. Both numbers are reported in the log.
    func testRenderTimeIsWithinBudget() {
        let raycaster = Raycaster(model: room)
        let camera = VirtualCamera(path: .tour(of: .canonical))
        let poses = (0..<5).map { camera.pose(at: Double($0) * 1.2) }
        // Warm up, then time the average of five frames from different viewpoints.
        _ = raycaster.render(cameraToWorld: poses[0], intrinsics: .iPhonePro)
        let start = DispatchTime.now().uptimeNanoseconds
        for pose in poses { _ = raycaster.render(cameraToWorld: pose, intrinsics: .iPhonePro) }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 / Double(poses.count)
        #if DEBUG
        let ceiling = 400.0
        let build = "debug"
        #else
        let ceiling = 20.0
        let build = "release"
        #endif
        print("RAYCASTER_TIMING: \(String(format: "%.2f", ms)) ms/frame (256×192, \(room.triangleCount) triangles, \(build), ceiling \(ceiling) ms)")
        XCTAssertLessThan(ms, ceiling, "raycaster averaged \(ms) ms per frame in a \(build) build")
        measure {
            _ = raycaster.render(cameraToWorld: poses[1], intrinsics: .iPhonePro)
        }
    }
}
