import Foundation
import simd

/// A scripted walk: waypoints at chest height with a look target and how long to spend
/// reaching each from the previous one. Position and look target are interpolated linearly
/// in time, so the linear and angular speeds a segment implies are what the tracking script
/// sees.
public struct CameraPath: Sendable, Equatable {
    public struct Waypoint: Sendable, Equatable {
        /// Where the camera is (world metres; y is the eye height).
        public var position: SIMD3<Float>
        /// Where it looks.
        public var lookAt: SIMD3<Float>
        /// Seconds taken to reach this waypoint from the previous one; ignored for the first.
        public var duration: TimeInterval

        public init(position: SIMD3<Float>, lookAt: SIMD3<Float>, duration: TimeInterval) {
            self.position = position
            self.lookAt = lookAt
            self.duration = duration
        }
    }

    public var waypoints: [Waypoint]

    public init(waypoints: [Waypoint]) {
        precondition(!waypoints.isEmpty, "a path needs at least one waypoint")
        self.waypoints = waypoints
    }

    /// Total scripted time.
    public var duration: TimeInterval { waypoints.dropFirst().reduce(0) { $0 + max(0, $1.duration) } }

    /// The height a hand-held phone is scanned at.
    public static let chestHeight: Float = 1.4

    /// Position and look target at `t` seconds, clamped to the ends.
    public func sample(at t: TimeInterval) -> (position: SIMD3<Float>, lookAt: SIMD3<Float>) {
        guard waypoints.count > 1, t > 0 else { return (waypoints[0].position, waypoints[0].lookAt) }
        var elapsed: TimeInterval = 0
        for i in 1..<waypoints.count {
            let segment = max(0, waypoints[i].duration)
            if t <= elapsed + segment || i == waypoints.count - 1 {
                let f = segment > 0 ? Float(min(1, max(0, (t - elapsed) / segment))) : 1
                let a = waypoints[i - 1], b = waypoints[i]
                return (a.position + (b.position - a.position) * f, a.lookAt + (b.lookAt - a.lookAt) * f)
            }
            elapsed += segment
        }
        return (waypoints.last!.position, waypoints.last!.lookAt)
    }

    /// The first `seconds` of the path: whole legs that fit, then a final waypoint at the pose
    /// the path would have reached, so speeds along the cut leg are unchanged.
    public func truncated(to seconds: TimeInterval) -> CameraPath {
        guard seconds < duration else { return self }
        var out: [Waypoint] = [waypoints[0]]
        var elapsed: TimeInterval = 0
        for i in 1..<waypoints.count {
            let segment = max(0, waypoints[i].duration)
            if elapsed + segment <= seconds {
                out.append(waypoints[i])
                elapsed += segment
                if elapsed == seconds { break }
            } else {
                let end = sample(at: seconds)
                out.append(Waypoint(position: end.position, lookAt: end.lookAt, duration: seconds - elapsed))
                break
            }
        }
        return CameraPath(waypoints: out)
    }

    /// Seconds per leg of a `tour`: a 1.6 m step and a quarter turn take this long, which is
    /// about 1.1 m/s and 65°/s, which stays under the excessive-motion thresholds with sway on top.
    public static let tourLegSeconds: TimeInterval = 1.5

    /// A tour of `spec` at a person's pace: a still second for tracking to initialise, then as
    /// many `tourLegSeconds` legs as `seconds` allows, each a step to the next corner of a
    /// small loop near the middle of the room while turning to face the next wall (south,
    /// east, north, west, and round again). Four legs bring the camera back to its start, so
    /// a loop closure late in an 8.5-second tour is plausible; a 4-second tour is two legs.
    public static func tour(of spec: RoomSpec, seconds: TimeInterval = 8.5, eyeHeight: Float = chestHeight) -> CameraPath {
        let usableWidth = spec.width - (spec.lCut?.cutWidth ?? 0)
        let cx = usableWidth / 2, cz = spec.depth / 2
        let rx = max(0.3, min(0.8, usableWidth / 2 - 0.9)), rz = max(0.3, min(0.8, spec.depth / 2 - 0.9))
        let h = eyeHeight
        let walls: [SIMD3<Float>] = [
            SIMD3(cx, h * 0.8, 0),            // south
            SIMD3(usableWidth, h * 0.8, cz),  // east
            SIMD3(cx, h * 0.8, spec.depth),   // north
            SIMD3(0, h * 0.8, cz),            // west
        ]
        let corners: [SIMD3<Float>] = [
            SIMD3(cx - rx, h, cz - rz), SIMD3(cx + rx, h, cz - rz), SIMD3(cx + rx, h, cz + rz), SIMD3(cx - rx, h, cz + rz),
        ]
        let legs = max(1, Int(((seconds - 1) / tourLegSeconds).rounded(.down)))
        var points: [Waypoint] = [
            Waypoint(position: corners[0], lookAt: walls[0], duration: 0),
            Waypoint(position: corners[0], lookAt: walls[0], duration: 1),
        ]
        for i in 1...legs {
            points.append(Waypoint(position: corners[i % 4], lookAt: walls[i % 4], duration: tourLegSeconds))
        }
        return CameraPath(waypoints: points)
    }
}

/// Turns a `CameraPath` into a stream of poses at a fixed rate, with the small sway of a hand
/// and a tracking-state script that behaves the way ARKit does at the start of a session and
/// under fast motion. Pure: `tick(_:)` is a function of the tick index, so any tick can be
/// recomputed.
public struct VirtualCamera: Sendable, Equatable {
    public struct Configuration: Sendable, Equatable {
        /// Ticks per second. ARKit delivers 60 Hz; 30 halves the work for the same coverage.
        public var frameRate: Double = 30
        public var intrinsics: CameraIntrinsics = .iPhonePro
        /// Peak sideways / vertical sway in metres, at 0.7 Hz and 1.1 Hz.
        public var swayAmplitude: SIMD2<Float> = SIMD2(0.02, 0.015)
        /// Seconds of `limited(initializing)` after the first tick before tracking is `normal`.
        public var initializingSeconds: TimeInterval = 1.0
        /// Linear speed above which a tick reports `limited(excessiveMotion)`.
        public var maxLinearSpeed: Float = 1.5
        /// Angular speed (degrees per second) above which a tick reports `limited(excessiveMotion)`.
        public var maxAngularSpeedDegrees: Float = 90
        /// Timestamp of tick 0. ARKit's clock is seconds since boot, so a large number.
        public var timestampOrigin: TimeInterval = 1000

        public init() {}
    }

    /// One tick's output.
    public struct Tick: Sendable, Equatable {
        public var index: Int
        public var time: TimeInterval
        public var timestamp: TimeInterval
        public var cameraToWorld: simd_float4x4
        public var trackingState: TrackingState
    }

    public var path: CameraPath
    public var configuration: Configuration

    public init(path: CameraPath, configuration: Configuration = Configuration()) {
        self.path = path
        self.configuration = configuration
    }

    /// Number of ticks over the path's duration, inclusive of both ends.
    public var tickCount: Int { Int((path.duration * configuration.frameRate).rounded(.down)) + 1 }

    public func time(ofTick index: Int) -> TimeInterval { Double(index) / configuration.frameRate }

    /// Camera-to-world at `t`: the path's pose plus sway.
    public func pose(at t: TimeInterval) -> simd_float4x4 {
        let (position, lookAt) = path.sample(at: t)
        let base = Self.lookAt(from: position, to: lookAt)
        let sway = configuration.swayAmplitude
        let dx = sway.x * Float(sin(2 * Double.pi * 0.7 * t))
        let dy = sway.y * Float(sin(2 * Double.pi * 1.1 * t))
        var m = base
        m.columns.3 += base.columns.0 * dx + base.columns.1 * dy
        m.columns.3.w = 1
        return m
    }

    /// The tick at `index`.
    public func tick(_ index: Int) -> Tick {
        let t = time(ofTick: index)
        let pose = pose(at: t)
        var state: TrackingState
        if index == 0 {
            state = .notAvailable
        } else if t < configuration.initializingSeconds {
            state = .limitedInitializing
        } else {
            state = .normal
            let previous = self.pose(at: time(ofTick: index - 1))
            let dt = Float(1 / configuration.frameRate)
            let linear = simd_length(pose.translation - previous.translation) / dt
            let angular = Self.angleDegrees(previous, pose) / dt
            if linear > configuration.maxLinearSpeed || angular > configuration.maxAngularSpeedDegrees {
                state = .limitedExcessiveMotion
            }
        }
        return Tick(index: index, time: t, timestamp: configuration.timestampOrigin + t, cameraToWorld: pose, trackingState: state)
    }

    /// Every tick of the path.
    public func ticks() -> [Tick] { (0..<tickCount).map(tick) }

    /// Camera-to-world for a camera at `eye` looking at `target` with +Y up: columns are right,
    /// up, back (the camera looks down −Z). Falls back to looking along −Z when `target == eye`
    /// or the view is vertical.
    public static func lookAt(from eye: SIMD3<Float>, to target: SIMD3<Float>) -> simd_float4x4 {
        var forward = target - eye
        if simd_length_squared(forward) < 1e-12 { forward = SIMD3(0, 0, -1) }
        forward = simd_normalize(forward)
        var right = simd_cross(forward, SIMD3(0, 1, 0))
        if simd_length_squared(right) < 1e-8 { right = SIMD3(1, 0, 0) }
        right = simd_normalize(right)
        let up = simd_cross(right, forward)
        return simd_float4x4(columns: (SIMD4(right, 0), SIMD4(up, 0), SIMD4(-forward, 0), SIMD4(eye, 1)))
    }

    /// The rotation between two poses, in degrees. The maths is `simd_float4x4`'s in the core
    /// module, because `FrameGate` needs the same answer for a real capture.
    public static func angleDegrees(_ a: simd_float4x4, _ b: simd_float4x4) -> Float {
        a.forwardAngleDegrees(to: b)
    }
}
