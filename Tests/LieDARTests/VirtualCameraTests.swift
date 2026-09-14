import Foundation
import simd
import XCTest
@testable import LieDAR
import LieDARSynthetic

final class VirtualCameraTests: XCTestCase {

    func testIntrinsicsAreTheStatedIPhoneProConstants() {
        let k = CameraIntrinsics.iPhonePro
        XCTAssertEqual(k.fx, 1340)
        XCTAssertEqual(k.fy, 1340)
        XCTAssertEqual(k.cx, 960)
        XCTAssertEqual(k.cy, 720)
        XCTAssertEqual(k.imageResolution, PixelSize(width: 1920, height: 1440))
        XCTAssertEqual(k.matrix.columnMajorArray, [1340, 0, 0, 0, 1340, 0, 960, 720, 1])
        // Horizontal field of view ≈ 71°: 2 · atan(960 / 1340).
        XCTAssertEqual(2 * atan(960.0 / 1340.0) * 180 / .pi, 71.2, accuracy: 0.1)
        let depth = k.scaled(to: CameraIntrinsics.depthResolution)
        XCTAssertEqual(depth.fx, 1340 * 256 / 1920, accuracy: 1e-4)
        XCTAssertEqual(depth.cx, 128)
        XCTAssertEqual(depth.cy, 96, accuracy: 1e-4)
    }

    func testLookAtBuildsARightHandedCameraToWorld() {
        // Facing −z from the origin is the identity.
        XCTAssertEqual(VirtualCamera.lookAt(from: .zero, to: SIMD3(0, 0, -5)), matrix_identity_float4x4)
        // Facing +x: the camera's −Z (column 2 negated) is +x, its +X (column 0) is +z (right-
        // handed: right = forward × up), up stays up.
        let m = VirtualCamera.lookAt(from: SIMD3(1, 2, 3), to: SIMD3(6, 2, 3))
        XCTAssertEqual(-m.columns.2.xyz, SIMD3(1, 0, 0))
        XCTAssertEqual(m.columns.0.xyz, SIMD3(0, 0, 1))
        XCTAssertEqual(m.columns.1.xyz, SIMD3(0, 1, 0))
        XCTAssertEqual(m.translation, SIMD3(1, 2, 3))
    }

    func testPathInterpolatesPositionAndLookTarget() {
        let path = CameraPath(waypoints: [
            .init(position: SIMD3(0, 1.4, 0), lookAt: SIMD3(0, 1, -5), duration: 0),
            .init(position: SIMD3(2, 1.4, 0), lookAt: SIMD3(4, 1, -5), duration: 2),
            .init(position: SIMD3(2, 1.4, 2), lookAt: SIMD3(4, 1, -5), duration: 1),
        ])
        XCTAssertEqual(path.duration, 3)
        XCTAssertEqual(path.sample(at: -1).position, SIMD3(0, 1.4, 0))
        XCTAssertEqual(path.sample(at: 1).position, SIMD3(1, 1.4, 0))
        XCTAssertEqual(path.sample(at: 1).lookAt, SIMD3(2, 1, -5))
        XCTAssertEqual(path.sample(at: 2.5).position, SIMD3(2, 1.4, 1))
        XCTAssertEqual(path.sample(at: 99).position, SIMD3(2, 1.4, 2))
    }

    func testTickCountAndTimestampsFollowTheRate() {
        let path = CameraPath.tour(of: .canonical, seconds: 4)
        XCTAssertEqual(path.duration, 4, "one still second plus two 1.5 s legs")
        var configuration = VirtualCamera.Configuration()
        configuration.frameRate = 30
        let camera = VirtualCamera(path: path, configuration: configuration)
        XCTAssertEqual(camera.tickCount, 121)
        XCTAssertEqual(camera.tick(0).timestamp, 1000)
        XCTAssertEqual(camera.tick(30).timestamp, 1001, accuracy: 1e-9)
        XCTAssertEqual(camera.tick(120).time, 4, accuracy: 1e-9)
    }

    func testSwayIsSmallAndDeterministic() {
        let camera = VirtualCamera(path: .tour(of: .canonical))
        var maxOffset: Float = 0
        for i in 0..<60 {
            let t = Double(i) / 30
            var noSway = camera
            noSway.configuration.swayAmplitude = .zero
            let offset = simd_length(camera.pose(at: t).translation - noSway.pose(at: t).translation)
            maxOffset = max(maxOffset, offset)
        }
        XCTAssertGreaterThan(maxOffset, 0.01, "the sway is there")
        XCTAssertLessThanOrEqual(maxOffset, 0.026, "and never more than the two amplitudes combined")
        XCTAssertEqual(camera.tick(17), camera.tick(17))
    }

    func testTrackingScriptStartsUnavailableThenInitialisesThenIsNormal() {
        let camera = VirtualCamera(path: .tour(of: .canonical))
        let ticks = camera.ticks()
        XCTAssertEqual(ticks[0].trackingState, .notAvailable)
        XCTAssertEqual(ticks[1].trackingState, .limitedInitializing)
        XCTAssertEqual(ticks[29].trackingState, .limitedInitializing, "still initialising just under a second in")
        XCTAssertEqual(ticks[30].trackingState, .normal, "normal from one second")
        let normal = ticks.filter { $0.trackingState == .normal }.count
        XCTAssertEqual(normal, ticks.count - 30, "a person's-pace tour never trips excessive motion")
    }

    func testExcessiveMotionWhenTheScriptMovesTooFast() {
        // 3 m in half a second: 6 m/s.
        let dash = CameraPath(waypoints: [
            .init(position: SIMD3(1, 1.4, 1), lookAt: SIMD3(1, 1.4, -5), duration: 0),
            .init(position: SIMD3(1, 1.4, 1), lookAt: SIMD3(1, 1.4, -5), duration: 1.5),
            .init(position: SIMD3(4, 1.4, 1), lookAt: SIMD3(4, 1.4, -5), duration: 0.5),
            .init(position: SIMD3(4, 1.4, 1), lookAt: SIMD3(4, 1.4, -5), duration: 1),
        ])
        let ticks = VirtualCamera(path: dash).ticks()
        let states = ticks.map(\.trackingState)
        XCTAssertEqual(states[45], .normal, "still, after initialising")
        XCTAssertEqual(states[50], .limitedExcessiveMotion, "mid-dash")
        XCTAssertEqual(states[59], .limitedExcessiveMotion)
        XCTAssertEqual(states[75], .normal, "still again")
        // A quarter turn in a tenth of a second: 900°/s.
        let spin = CameraPath(waypoints: [
            .init(position: SIMD3(1, 1.4, 1), lookAt: SIMD3(1, 1.4, -5), duration: 0),
            .init(position: SIMD3(1, 1.4, 1), lookAt: SIMD3(1, 1.4, -5), duration: 1.5),
            .init(position: SIMD3(1, 1.4, 1), lookAt: SIMD3(7, 1.4, 1), duration: 0.1),
            .init(position: SIMD3(1, 1.4, 1), lookAt: SIMD3(7, 1.4, 1), duration: 1),
        ])
        let spinStates = VirtualCamera(path: spin).ticks().map(\.trackingState)
        XCTAssertEqual(spinStates[46], .limitedExcessiveMotion, "during the spin")
        XCTAssertEqual(spinStates[60], .normal)
    }
}
