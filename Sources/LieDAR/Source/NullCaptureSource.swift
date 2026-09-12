import CoreGraphics
import Foundation
import simd

/// A source that produces nothing: never available, streams that finish at once, an empty
/// mesh. It exists so a consumer can be built and tested against the seam before any real
/// source lands, and so tests have a `CaptureSource` to hand to code that needs one.
public final class NullCaptureSource: CaptureSource {
    public var isAvailable: Bool { false }
    public var cameraAuthorized: Bool { true }

    public init() {}

    public func start() throws {}
    public func stop() {}

    public var samples: AsyncStream<CameraSample> {
        AsyncStream { $0.finish() }
    }

    public var anchorEvents: AsyncStream<AnchorEvent> {
        AsyncStream { $0.finish() }
    }

    public func meshSnapshot() -> [MeshAnchorPayload] { [] }

    public func makeCaptureView() -> CaptureViewRepresentable { NullCaptureView() }

    public func raycast(screenPoint: CGPoint) -> SIMD3<Float>? { nil }
}

/// The view a `NullCaptureSource` offers: nothing to draw.
public final class NullCaptureView: CaptureViewRepresentable {
    public init() {}
}
