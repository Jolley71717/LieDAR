import CoreGraphics
import Foundation
import simd

/// The seam. An app's capture session talks to one of these and never to ARKit directly, so the
/// same session code runs against ARKit on a device, a recorded capture on replay, or a
/// synthetic room on the simulator. Every source is a peer; nothing downstream branches on
/// which one it is.
///
/// Lifecycle: check `isAvailable` (and `cameraAuthorized` when diagnosing an empty capture),
/// `start()`, consume `samples` and `anchorEvents`, call `meshSnapshot()` at stop time, then
/// `stop()`. The mesh is asked for, never fished out of a frame.
public protocol CaptureSource: AnyObject, Sendable {
    /// Whether this source can produce data on this machine right now. Replaces the static
    /// "does this device support scene reconstruction" query, which is false on every simulator
    /// regardless of what the source could do.
    var isAvailable: Bool { get }

    /// Whether the camera the source needs is authorized. A source with no camera reports `true`.
    var cameraAuthorized: Bool { get }

    /// Begins producing samples and anchor events. Throws when the source cannot start (for
    /// example a replay folder that does not exist).
    func start() throws

    /// Stops producing. The streams finish; `meshSnapshot()` still answers with the last state.
    func stop()

    /// One value per camera frame, cheap to construct. Frames that pass the consumer's gating
    /// are materialized into a `FramePayload` on demand.
    var samples: AsyncStream<CameraSample> { get }

    /// Mesh anchors being added, updated and removed as reconstruction proceeds.
    var anchorEvents: AsyncStream<AnchorEvent> { get }

    /// Every mesh anchor the source currently holds, in full. Called at stop time to write the
    /// mesh; this is the only way to get it.
    func meshSnapshot() -> [MeshAnchorPayload]

    /// The on-screen view for this source: the camera feed on a device, a rendered preview on
    /// the simulator. The concrete type is platform-specific and lives in a UI module.
    func makeCaptureView() -> CaptureViewRepresentable

    /// The world-space point under a screen point of the capture view, for placing annotations,
    /// or `nil` when nothing is there.
    func raycast(screenPoint: CGPoint) -> SIMD3<Float>?
}

/// Marker for whatever a `CaptureSource` puts on screen. UI modules (`LieDARUI`, an app's own
/// views) conform their platform view types; this module deliberately knows nothing about UIKit
/// or AppKit.
public protocol CaptureViewRepresentable: AnyObject {}

/// One camera frame as it arrives. Pose, time and tracking only, so a consumer can decide
/// whether to keep it before paying for the buffers. `materialize()` copies the depth,
/// confidence and colour planes and must be called **while the producer's frame is still
/// alive**; on ARKit that means synchronously in the delegate, which is why the closure and not
/// the payload is what crosses the seam.
public struct CameraSample: Sendable {
    /// Camera-to-world.
    public var transform: simd_float4x4
    /// Seconds on a monotonic clock; only differences matter.
    public var timestamp: TimeInterval
    public var trackingState: TrackingState
    /// Copies the frame's buffers into a payload, or returns `nil` when the frame has no depth
    /// or the copy failed. The payload's `meta.index` is whatever the closure was built with;
    /// consumers that number frames overwrite it.
    public var materialize: @Sendable () -> FramePayload?

    public init(transform: simd_float4x4, timestamp: TimeInterval, trackingState: TrackingState,
                materialize: @escaping @Sendable () -> FramePayload?) {
        self.transform = transform
        self.timestamp = timestamp
        self.trackingState = trackingState
        self.materialize = materialize
    }
}

/// A change to the set of mesh anchors.
public enum AnchorEvent: Sendable {
    /// A new anchor. Its payload is complete as of this event.
    case added(MeshAnchorPayload)
    /// An existing anchor's geometry or transform changed; the payload replaces the old one.
    case updated(MeshAnchorPayload)
    /// The anchor with this id is gone. Reconstruction may re-add the same region under a new id.
    case removed(UUID)

    public var anchorID: UUID {
        switch self {
        case .added(let anchor), .updated(let anchor): return anchor.id
        case .removed(let id): return id
        }
    }
}
