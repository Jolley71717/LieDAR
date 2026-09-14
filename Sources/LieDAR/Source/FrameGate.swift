import Foundation
import simd

/// The write-gating rule a capture session applies to camera samples (PLAN "Gating is real"):
/// a frame is written only when tracking is `.normal` **and** the camera has moved at least
/// `minimumDistance` or turned at least `minimumAngleDegrees` since the last written frame, or
/// `maximumInterval` seconds have passed. The first normal frame always passes. A scripted path
/// that does not move therefore writes one frame every `maximumInterval` and no more, which is
/// why `frameCount ≠ frames fed`.
public struct FrameGate: Sendable, Equatable {
    public var minimumDistance: Float
    public var minimumAngleDegrees: Float
    public var maximumInterval: TimeInterval

    private var lastTransform: simd_float4x4?
    private var lastTimestamp: TimeInterval = 0

    public init(minimumDistance: Float = 0.15, minimumAngleDegrees: Float = 10, maximumInterval: TimeInterval = 0.5) {
        self.minimumDistance = minimumDistance
        self.minimumAngleDegrees = minimumAngleDegrees
        self.maximumInterval = maximumInterval
    }

    /// Whether a frame with this pose, time and tracking state should be written; when it
    /// should, the gate remembers it as the last written frame.
    public mutating func admit(transform: simd_float4x4, timestamp: TimeInterval, trackingState: TrackingState) -> Bool {
        guard trackingState.isNormal else { return false }
        if let last = lastTransform {
            let moved = simd_length(transform.translation - last.translation) >= minimumDistance
            let turned = last.forwardAngleDegrees(to: transform) >= minimumAngleDegrees
            let stale = timestamp - lastTimestamp >= maximumInterval
            guard moved || turned || stale else { return false }
        }
        lastTransform = transform
        lastTimestamp = timestamp
        return true
    }

    public mutating func admit(_ sample: CameraSample) -> Bool {
        admit(transform: sample.transform, timestamp: sample.timestamp, trackingState: sample.trackingState)
    }
}
