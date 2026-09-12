import Foundation
import simd

/// One captured frame, fully copied out of its source. Everything a `CaptureRecorder` needs to
/// write `frames/NNNNNN.*`, and nothing that refers back to the producer — no pixel buffer, no
/// ARKit frame — so the value can be handed to another task or actor freely (RT-3).
public struct FramePayload: Sendable {
    /// Distance from the camera plane in metres, one `Float32` per pixel. Typically 256 × 192.
    public var depth: Plane<Float32>
    /// Per-pixel confidence, same shape as `depth`: 0 low, 1 medium, 2 high. `nil` when the
    /// source has none.
    public var confidence: Plane<UInt8>?
    /// The colour image, if the source provides one. Its size should match `meta.imageResolution`.
    public var color: ColorPlanes?
    /// Pose, intrinsics, timestamp and tracking state — the frame's `NNNNNN.json`.
    public var meta: FrameMeta

    public init(depth: Plane<Float32>, confidence: Plane<UInt8>?, color: ColorPlanes?, meta: FrameMeta) {
        self.depth = depth
        self.confidence = confidence
        self.color = color
        self.meta = meta
    }
}

/// The camera's tracking quality for a frame, as the on-disk string form in `FrameMeta`.
/// The raw values are the exact strings the format uses.
public enum TrackingState: String, Sendable, Codable, CaseIterable, Equatable {
    case normal
    case notAvailable
    case limitedInitializing = "limited.initializing"
    case limitedExcessiveMotion = "limited.excessiveMotion"
    case limitedInsufficientFeatures = "limited.insufficientFeatures"
    case limitedRelocalizing = "limited.relocalizing"
    /// A limited state this version does not name.
    case limitedUnknown = "limited.unknown"
    /// The session reported an error.
    case failed
    /// The session was interrupted (backgrounded, camera taken by another app).
    case interrupted
    /// A state this version does not name.
    case unknown

    /// Only `.normal` frames are written by a gated capture session.
    public var isNormal: Bool { self == .normal }
}

/// `frames/NNNNNN.json` — see `docs/CAPTURE_FORMAT.md`. Field names and types are the on-disk
/// contract; do not rename them.
public struct FrameMeta: Codable, Sendable, Equatable {
    /// Frame index; also the zero-padded base name of the frame's files.
    public var index: Int
    /// Seconds on a monotonic clock (ARKit's `ARFrame.timestamp`); only differences matter.
    public var timestamp: TimeInterval
    /// 16 floats, column-major camera-to-world (`element(row r, col c)` at `c*4 + r`).
    public var cameraTransform: [Float]
    /// 9 floats, column-major pinhole intrinsics for `imageResolution`: `[fx 0 0  0 fy 0  cx cy 1]`.
    public var intrinsics: [Float]
    /// Colour image size the intrinsics refer to.
    public var imageResolution: PixelSize
    /// Depth (and confidence) map size.
    public var depthResolution: PixelSize
    /// `TrackingState.rawValue`. Stored as a string so a reader never fails on a value it does
    /// not know; use `state` for the typed view.
    public var trackingState: String

    public init(index: Int,
                timestamp: TimeInterval,
                cameraTransform: [Float],
                intrinsics: [Float],
                imageResolution: PixelSize,
                depthResolution: PixelSize,
                trackingState: TrackingState) {
        self.init(index: index, timestamp: timestamp, cameraTransform: cameraTransform, intrinsics: intrinsics,
                  imageResolution: imageResolution, depthResolution: depthResolution, trackingState: trackingState.rawValue)
    }

    public init(index: Int,
                timestamp: TimeInterval,
                cameraTransform: [Float],
                intrinsics: [Float],
                imageResolution: PixelSize,
                depthResolution: PixelSize,
                trackingState: String) {
        self.index = index
        self.timestamp = timestamp
        self.cameraTransform = cameraTransform
        self.intrinsics = intrinsics
        self.imageResolution = imageResolution
        self.depthResolution = depthResolution
        self.trackingState = trackingState
    }

    /// Convenience over the simd matrices.
    public init(index: Int,
                timestamp: TimeInterval,
                cameraTransform: simd_float4x4,
                intrinsics: simd_float3x3,
                imageResolution: PixelSize,
                depthResolution: PixelSize,
                trackingState: TrackingState) {
        self.init(index: index, timestamp: timestamp,
                  cameraTransform: cameraTransform.columnMajorArray, intrinsics: intrinsics.columnMajorArray,
                  imageResolution: imageResolution, depthResolution: depthResolution, trackingState: trackingState)
    }

    /// `trackingState` as an enum; `.unknown` for a string this version does not name.
    public var state: TrackingState { TrackingState(rawValue: trackingState) ?? .unknown }

    /// `cameraTransform` as a matrix, or `nil` when it does not hold exactly 16 values.
    public var cameraMatrix: simd_float4x4? { simd_float4x4(columnMajorArray: cameraTransform) }

    /// `intrinsics` as a matrix, or `nil` when it does not hold exactly 9 values.
    public var intrinsicsMatrix: simd_float3x3? { simd_float3x3(columnMajorArray: intrinsics) }
}
