import Foundation
import simd

/// Which controls are held right now. A set, so several can be held at once, and so the state
/// machine never learns whether they came from a key, a button or a test.
public struct WalkInput: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let forward = WalkInput(rawValue: 1 << 0)
    public static let back = WalkInput(rawValue: 1 << 1)
    public static let strafeLeft = WalkInput(rawValue: 1 << 2)
    public static let strafeRight = WalkInput(rawValue: 1 << 3)
    public static let turnLeft = WalkInput(rawValue: 1 << 4)
    public static let turnRight = WalkInput(rawValue: 1 << 5)
    public static let lookUp = WalkInput(rawValue: 1 << 6)
    public static let lookDown = WalkInput(rawValue: 1 << 7)

    /// The control a letter key drives, on the WASD layout with QE to turn and RF to look, or
    /// `nil` for a key that drives nothing. Case is ignored.
    public static func forKey(_ key: Character) -> WalkInput? {
        switch Character(key.lowercased()) {
        case "w": return .forward
        case "s": return .back
        case "a": return .strafeLeft
        case "d": return .strafeRight
        case "q": return .turnLeft
        case "e": return .turnRight
        case "r": return .lookUp
        case "f": return .lookDown
        default: return nil
        }
    }
}

/// Where a person walking the room stands and looks, and the rules that move them.
///
/// A value type with no SwiftUI in it, because this is the half of the controls a test can pin.
/// The gestures and key handling are in `SimulatorControls`, and they do one thing: turn what is
/// held into a `WalkInput` and hand it here.
///
/// Height is pinned to `eyeHeight` on every step, so nothing a person does lifts the camera off
/// chest height. Looking up and down changes where the camera points and never where it is.
public struct Walker: Sendable, Equatable {
    /// World position, in metres. `y` is rewritten to `eyeHeight` by every `apply`.
    public var position: SIMD3<Float>
    /// Radians about +Y. Zero looks along −Z, and turning left increases it.
    public var yaw: Float
    /// Radians above the horizon, clamped to ±`pitchLimit`.
    public var pitch: Float
    /// The height the camera is held at. `CameraPath.chestHeight` by default, which is what the
    /// scripted tour walks at.
    public var eyeHeight: Float
    /// Metres per second while a move control is held.
    public var walkSpeed: Float
    /// Radians per second while a turn control is held.
    public var turnSpeed: Float
    /// Radians per second while a look control is held.
    public var lookSpeed: Float
    /// How far from the horizon the camera may look, in radians. Short of vertical, so the
    /// camera basis never degenerates.
    public var pitchLimit: Float
    /// The walls to bump into, or `nil` to walk through everything.
    public var bounds: WalkBounds?

    public init(position: SIMD3<Float>, yaw: Float = 0, pitch: Float = 0,
                eyeHeight: Float = CameraPath.chestHeight, walkSpeed: Float = 1.2,
                turnSpeed: Float = .pi / 2, lookSpeed: Float = .pi / 2,
                pitchLimit: Float = .pi / 3, bounds: WalkBounds? = nil) {
        self.position = SIMD3(position.x, eyeHeight, position.z)
        self.yaw = yaw
        self.pitch = pitch
        self.eyeHeight = eyeHeight
        self.walkSpeed = walkSpeed
        self.turnSpeed = turnSpeed
        self.lookSpeed = lookSpeed
        self.pitchLimit = pitchLimit
        self.bounds = bounds
    }

    /// Standing in the middle of `spec` at chest height, facing the south wall, with the room's
    /// outline as the walls to bump into.
    public static func standing(in spec: RoomSpec, eyeHeight: Float = CameraPath.chestHeight) -> Walker {
        let usableWidth = spec.width - (spec.lCut?.cutWidth ?? 0)
        return Walker(position: SIMD3(usableWidth / 2, eyeHeight, spec.depth / 2),
                      eyeHeight: eyeHeight, bounds: .outline(of: spec))
    }

    /// A walker at `position` aimed at `target`, which is how a scripted waypoint is written.
    /// Yaw and pitch are read off the direction; the pitch is clamped like any other.
    public static func looking(from position: SIMD3<Float>, at target: SIMD3<Float>,
                               eyeHeight: Float = CameraPath.chestHeight,
                               bounds: WalkBounds? = nil) -> Walker {
        let d = target - SIMD3(position.x, eyeHeight, position.z)
        let length = simd_length(d)
        var walker = Walker(position: position, eyeHeight: eyeHeight, bounds: bounds)
        guard length > 1e-6 else { return walker }
        walker.yaw = atan2(-d.x, -d.z)
        walker.pitch = min(walker.pitchLimit, max(-walker.pitchLimit, asin(min(1, max(-1, d.y / length)))))
        return walker
    }

    /// The direction the camera points, including pitch.
    public var forward: SIMD3<Float> {
        let cp = cos(pitch)
        return SIMD3(-sin(yaw) * cp, sin(pitch), -cos(yaw) * cp)
    }

    /// The direction the camera points with pitch dropped, which is the direction walking goes.
    public var flatForward: SIMD3<Float> { SIMD3(-sin(yaw), 0, -cos(yaw)) }

    /// The direction strafing right goes.
    public var right: SIMD3<Float> { SIMD3(cos(yaw), 0, -sin(yaw)) }

    /// Camera-to-world for this pose, built the same way the scripted camera builds one.
    public var cameraToWorld: simd_float4x4 {
        VirtualCamera.lookAt(from: position, to: position + forward)
    }

    /// Advances by `seconds` with `held` down: turn and look first, then a step in whatever
    /// direction the move controls add up to, at `walkSpeed` no matter how many are held. The
    /// step is resolved against `bounds`, and the height is pinned last.
    public mutating func apply(_ held: WalkInput, for seconds: TimeInterval) {
        let dt = Float(max(0, seconds))

        if held.contains(.turnLeft) { yaw += turnSpeed * dt }
        if held.contains(.turnRight) { yaw -= turnSpeed * dt }
        yaw = Walker.wrapped(yaw)
        if held.contains(.lookUp) { pitch += lookSpeed * dt }
        if held.contains(.lookDown) { pitch -= lookSpeed * dt }
        pitch = min(pitchLimit, max(-pitchLimit, pitch))

        var direction = SIMD3<Float>.zero
        if held.contains(.forward) { direction += flatForward }
        if held.contains(.back) { direction -= flatForward }
        if held.contains(.strafeRight) { direction += right }
        if held.contains(.strafeLeft) { direction -= right }
        if simd_length_squared(direction) > 1e-12 {
            // Normalised, so holding forward and a strafe together covers the same ground as
            // holding one of them rather than 1.41 times as much.
            let step = simd_normalize(direction) * walkSpeed * dt
            let from = SIMD2(position.x, position.z)
            var to = from + SIMD2(step.x, step.z)
            if let bounds { to = bounds.resolve(from: from, to: to) }
            position.x = to.x
            position.z = to.y
        }
        position.y = eyeHeight
    }

    /// `angle` folded into −pi to pi, so two full turns read the same as none.
    static func wrapped(_ angle: Float) -> Float {
        var a = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if a > .pi { a -= 2 * .pi }
        if a <= -.pi { a += 2 * .pi }
        return a
    }
}
