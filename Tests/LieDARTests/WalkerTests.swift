import Foundation
import simd
import XCTest
@testable import LieDAR
import LieDARUI

/// `Walker` is the half of `SimulatorControls` that does not need a screen: what is held goes
/// in, a camera pose comes out. Everything a person can do to the camera is pinned here, so the
/// gestures and key handling above it stay as thin as they look.
final class WalkerTests: XCTestCase {
    let room = RoomSpec.canonical

    func testWalkingForwardCoversWalkSpeedInOneSecond() {
        var walker = Walker(position: SIMD3(2.5, 1.4, 2.0))
        walker.apply(.forward, for: 1)
        XCTAssertEqual(walker.position.x, 2.5, accuracy: 1e-5, "forward at yaw 0 does not move sideways")
        XCTAssertEqual(walker.position.z, 2.0 - 1.2, accuracy: 1e-5, "1.2 m/s for a second, along −Z")
    }

    func testWalkingBackIsTheOppositeOfWalkingForward() {
        var walker = Walker(position: SIMD3(2.5, 1.4, 2.0))
        walker.apply(.forward, for: 0.5)
        walker.apply(.back, for: 0.5)
        XCTAssertEqual(walker.position.z, 2.0, accuracy: 1e-5)
    }

    func testHeightStaysAtChestHeightWhateverIsHeld() {
        var walker = Walker(position: SIMD3(2.5, 99, 2.0))
        XCTAssertEqual(walker.position.y, CameraPath.chestHeight, accuracy: 1e-6, "pinned at init")
        // Position is settable, so a host can put the camera anywhere. Every step pins it back.
        walker.position.y = 99
        walker.apply([.forward, .strafeRight, .lookUp, .turnLeft], for: 0.4)
        XCTAssertEqual(walker.position.y, CameraPath.chestHeight, accuracy: 1e-6, "and after a step")
        walker.position.y = -3
        walker.apply(.lookUp, for: 5)
        XCTAssertEqual(walker.position.y, CameraPath.chestHeight, accuracy: 1e-6, "looking up does not lift the camera")
    }

    func testTurningComposes() {
        var walker = Walker(position: SIMD3(2.5, 1.4, 2.0))
        walker.apply(.turnLeft, for: 0.5)
        walker.apply(.turnLeft, for: 0.5)
        XCTAssertEqual(walker.yaw, .pi / 2, accuracy: 1e-5, "two quarter-turns at 90 degrees a second")
        XCTAssertEqual(walker.flatForward.x, -1, accuracy: 1e-5, "a left quarter-turn from −Z faces −X")
        XCTAssertEqual(walker.flatForward.z, 0, accuracy: 1e-5)
        walker.apply(.turnRight, for: 1)
        XCTAssertEqual(walker.yaw, 0, accuracy: 1e-5, "and turning back the other way undoes it")
        walker.apply(.turnRight, for: 1)
        XCTAssertEqual(walker.yaw, -.pi / 2, accuracy: 1e-5, "a right quarter-turn from −Z is the other sign")
        XCTAssertEqual(walker.flatForward.x, 1, accuracy: 1e-5, "and faces +X")
    }

    func testWalkingFollowsTheDirectionTurnedTo() {
        var walker = Walker(position: SIMD3(2.5, 1.4, 2.0))
        walker.apply(.turnLeft, for: 1)
        walker.apply(.forward, for: 1)
        XCTAssertEqual(walker.position.x, 2.5 - 1.2, accuracy: 1e-5, "after a left turn, forward is −X")
        XCTAssertEqual(walker.position.z, 2.0, accuracy: 1e-5)
    }

    func testStrafingGoesSidewaysAndNotForwards() {
        var walker = Walker(position: SIMD3(2.5, 1.4, 2.0))
        walker.apply(.strafeRight, for: 1)
        XCTAssertEqual(walker.position.x, 2.5 + 1.2, accuracy: 1e-5)
        XCTAssertEqual(walker.position.z, 2.0, accuracy: 1e-5)
        XCTAssertEqual(walker.yaw, 0, accuracy: 1e-6, "strafing does not turn the camera")
    }

    func testHoldingTwoMovesIsNotFasterThanHoldingOne() {
        var straight = Walker(position: SIMD3(2.5, 1.4, 2.0))
        straight.apply(.forward, for: 1)
        var diagonal = Walker(position: SIMD3(2.5, 1.4, 2.0))
        diagonal.apply([.forward, .strafeRight], for: 1)
        let a = simd_length(straight.position - SIMD3(2.5, 1.4, 2.0))
        let b = simd_length(diagonal.position - SIMD3(2.5, 1.4, 2.0))
        XCTAssertEqual(b, a, accuracy: 1e-5, "a diagonal covers the same ground as a straight line")
    }

    func testLookingAimsTheCameraAndLeavesItWhereItIs() {
        var walker = Walker(position: SIMD3(2.5, 1.4, 2.0))
        walker.apply(.lookUp, for: 0.25)
        XCTAssertEqual(walker.pitch, .pi / 8, accuracy: 1e-5)
        XCTAssertGreaterThan(walker.forward.y, 0, "the aim rises")
        XCTAssertEqual(walker.position, SIMD3(2.5, 1.4, 2.0), "and the camera has not moved")
        XCTAssertEqual(walker.flatForward.y, 0, accuracy: 1e-6, "walking is still level")
    }

    func testPitchStopsShortOfVertical() {
        var walker = Walker(position: SIMD3(2.5, 1.4, 2.0))
        walker.apply(.lookUp, for: 10)
        XCTAssertEqual(walker.pitch, walker.pitchLimit, accuracy: 1e-6)
        XCTAssertLessThan(walker.pitchLimit, .pi / 2, "short of straight up, so the camera basis stays defined")
        walker.apply(.lookDown, for: 20)
        XCTAssertEqual(walker.pitch, -walker.pitchLimit, accuracy: 1e-6)
    }

    func testCameraToWorldLooksWhereTheWalkerLooks() {
        var walker = Walker(position: SIMD3(2.5, 1.4, 2.0))
        walker.apply(.turnLeft, for: 0.5)
        walker.apply(.lookDown, for: 0.2)
        let m = walker.cameraToWorld
        XCTAssertEqual(m.columns.3.xyz, walker.position, "the camera is where the walker is")
        let back = SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        XCTAssertEqual(simd_length(back + walker.forward), 0, accuracy: 1e-5, "the third column is the way it came from")
    }

    // MARK: Walls

    func testWalkingIntoAWallStopsAtTheBodyRadius() {
        var walker = Walker.standing(in: room)
        XCTAssertNotNil(walker.bounds, "a walker standing in a room has walls to bump into")
        walker.apply(.forward, for: 10)
        XCTAssertEqual(walker.position.z, walker.bounds!.radius, accuracy: 1e-4, "stopped short of the south wall")
        XCTAssertEqual(walker.position.x, 2.5, accuracy: 1e-4, "and did not slide along it")
    }

    func testWalkingIntoACornerStopsInBothDirections() {
        var walker = Walker(position: SIMD3(0.8, 1.4, 0.8), yaw: .pi / 4, bounds: .outline(of: room))
        walker.apply(.forward, for: 2)
        XCTAssertEqual(walker.position.x, 0.3, accuracy: 1e-4)
        XCTAssertEqual(walker.position.z, 0.3, accuracy: 1e-4)
    }

    func testAWalkerWithNoBoundsWalksStraightOut() {
        var walker = Walker(position: SIMD3(2.5, 1.4, 2.0), bounds: nil)
        walker.apply(.forward, for: 10)
        XCTAssertEqual(walker.position.z, 2.0 - 12, accuracy: 1e-4, "no walls means no stopping")
    }

    // MARK: Bounds on their own

    func testClosestPointOnAWallClampsToItsEnds() {
        let wall = WalkBounds.Wall(start: SIMD2(0, 0), end: SIMD2(5, 0))
        XCTAssertEqual(wall.closestPoint(to: SIMD2(2, 1)), SIMD2(2, 0))
        XCTAssertEqual(wall.closestPoint(to: SIMD2(-3, 1)), SIMD2(0, 0), "past the start")
        XCTAssertEqual(wall.closestPoint(to: SIMD2(9, 1)), SIMD2(5, 0), "past the end")
    }

    func testResolveLeavesALegalStepAlone() {
        let bounds = WalkBounds.outline(of: room)
        let landed = bounds.resolve(from: SIMD2(2.5, 2.0), to: SIMD2(2.5, 1.5))
        XCTAssertEqual(landed.x, 2.5, accuracy: 1e-5)
        XCTAssertEqual(landed.y, 1.5, accuracy: 1e-5, "a step that stays in the room is not touched")
    }

    func testResolvePushesAStepOutOfAWallItLandedTooCloseTo() {
        let bounds = WalkBounds.outline(of: room)
        let landed = bounds.resolve(from: SIMD2(2.5, 0.5), to: SIMD2(2.5, 0.1))
        XCTAssertEqual(landed.y, bounds.radius, accuracy: 1e-5, "pushed back to the body radius")
    }

    func testTheOutlineOfARoomIsItsWallSegments() {
        let bounds = WalkBounds.outline(of: room)
        XCTAssertEqual(bounds.walls.count, RoomModel.wallSegments(of: room).count)
        XCTAssertEqual(bounds.walls.first?.start, SIMD2(0, 0))
    }

    // MARK: Keys

    func testTheKeyboardLayoutIsWASDWithQEAndRF() {
        XCTAssertEqual(WalkInput.forKey("w"), .forward)
        XCTAssertEqual(WalkInput.forKey("S"), .back, "case does not matter")
        XCTAssertEqual(WalkInput.forKey("a"), .strafeLeft)
        XCTAssertEqual(WalkInput.forKey("d"), .strafeRight)
        XCTAssertEqual(WalkInput.forKey("q"), .turnLeft)
        XCTAssertEqual(WalkInput.forKey("e"), .turnRight)
        XCTAssertEqual(WalkInput.forKey("r"), .lookUp)
        XCTAssertEqual(WalkInput.forKey("f"), .lookDown)
        XCTAssertNil(WalkInput.forKey("z"))
    }
}

/// The two ways a host starts a walker off without writing angles by hand.
final class WalkerStartTests: XCTestCase {
    func testAWalkerAimedAtATargetFacesIt() {
        let walker = Walker.looking(from: SIMD3(2.5, 1.4, 3.0), at: SIMD3(2.5, 1.4, 0))
        XCTAssertEqual(walker.yaw, 0, accuracy: 1e-5, "looking along −Z is yaw zero")
        XCTAssertEqual(walker.pitch, 0, accuracy: 1e-5)

        let east = Walker.looking(from: SIMD3(2.5, 1.4, 2.0), at: SIMD3(5, 1.4, 2.0))
        XCTAssertEqual(east.flatForward.x, 1, accuracy: 1e-5, "looking at +X faces +X")
        XCTAssertEqual(east.flatForward.z, 0, accuracy: 1e-5)

        let down = Walker.looking(from: SIMD3(2.5, 1.4, 3.0), at: SIMD3(2.5, 0, 2.0))
        XCTAssertLessThan(down.pitch, 0, "looking at the floor tilts down")
        XCTAssertGreaterThanOrEqual(down.pitch, -down.pitchLimit, "and no further than the limit")
        XCTAssertEqual(down.position.y, CameraPath.chestHeight, accuracy: 1e-6)
    }

    func testTheBoxOfAModelIsItsFloorPlaneBounds() {
        let model = RoomModel.parametric(.canonical)
        let bounds = WalkBounds.box(of: model)
        XCTAssertEqual(bounds.walls.count, 4, "four walls for a box")
        var walker = Walker(position: SIMD3(2.5, 1.4, 2.0), bounds: bounds)
        walker.apply(.forward, for: 10)
        XCTAssertEqual(walker.position.z, bounds.radius, accuracy: 1e-3, "the box stops a walk south")
        walker.yaw = .pi
        walker.apply(.forward, for: 10)
        XCTAssertEqual(walker.position.z, 4 - bounds.radius, accuracy: 1e-3, "and a walk north")
    }
}
