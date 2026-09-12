import CoreGraphics
import Foundation
import simd

/// A `CaptureSource` that lies about LiDAR: a parametric room, a scripted camera, a CPU
/// raycaster for depth and confidence, an anchor chunker for the mesh and a degradation model
/// for the labels. Always available, camera always "authorized", no hardware anywhere.
///
/// Samples arrive at the virtual camera's rate (paced to the wall clock when
/// `Configuration.realTime` is on, as fast as the consumer drains them otherwise). Each tick
/// also renders a coarse frame to discover anchors, so `anchorEvents` and `meshSnapshot()`
/// reflect what the camera has actually looked at. `materialize()` renders the full depth map
/// and a flat-shaded per-class colour image on demand, so frames the consumer's gate rejects
/// cost nothing.
///
/// Concurrency invariant (why `@unchecked Sendable`): `chunker`, `state` and the producer task
/// are touched only inside `lock.withLock`; everything else is immutable after `init`. Stream
/// continuations are thread-safe by contract.
public final class SyntheticCaptureSource: CaptureSource, @unchecked Sendable {
    /// A scripted loop-closure: at `time` seconds into the path every anchor moves by
    /// `translation` at once.
    public struct LoopClosure: Sendable, Equatable {
        public var time: TimeInterval
        public var translation: SIMD3<Float>

        public init(time: TimeInterval, translation: SIMD3<Float>) {
            self.time = time
            self.translation = translation
        }
    }

    public struct Configuration: Sendable {
        public var room: RoomModel
        public var path: CameraPath
        public var camera = VirtualCamera.Configuration()
        /// Size of the depth and confidence maps a materialized frame carries.
        public var depthResolution = CameraIntrinsics.depthResolution
        /// Size of the colour image, or `nil` for depth-only frames. At most 960 × 720.
        public var colorResolution: PixelSize? = PixelSize(width: 960, height: 720)
        /// Size of the per-tick render used to discover anchors; small, because it runs for
        /// every tick whether or not the frame is materialized.
        public var discoveryResolution = PixelSize(width: 64, height: 48)
        public var chunker = AnchorChunker.Configuration()
        public var degradation: DegradationModel
        public var loopClosure: LoopClosure?
        /// Pace samples to the wall clock at `camera.frameRate`. Off for tests and fixtures.
        public var realTime = true
        /// Produce no samples and no anchors at all — the "Start, then Stop at once" path a
        /// consumer must discard. The streams finish immediately on `start()`.
        public var zeroFrames = false

        public init(room: RoomModel, path: CameraPath, degradation: DegradationModel) {
            self.room = room
            self.path = path
            self.degradation = degradation
        }

        /// Everything from one seed: a random room, a tour of it, seeded churn and
        /// degradation at the suite defaults, and a loop closure of a few centimetres three
        /// quarters of the way round.
        public init(seed: UInt64, seconds: TimeInterval = 8.5) {
            let spec = RoomSpec.random(seed: seed)
            self.init(room: .parametric(spec), path: .tour(of: spec, seconds: seconds), degradation: DegradationModel(seed: seed))
            chunker.seed = seed
            loopClosure = LoopClosure(time: seconds * 0.75, translation: SIMD3(0.03, 0.01, -0.02))
        }
    }

    private enum State {
        case idle, running, stopped
    }

    public let configuration: Configuration
    public let raycaster: Raycaster
    public let camera: VirtualCamera

    private let lock = NSLock()
    private var chunker: AnchorChunker
    private var state: State = .idle
    private var producer: Task<Void, Never>?
    private var loopClosureApplied = false

    private let sampleStream: AsyncStream<CameraSample>
    private let sampleContinuation: AsyncStream<CameraSample>.Continuation
    private let anchorStream: AsyncStream<AnchorEvent>
    private let anchorContinuation: AsyncStream<AnchorEvent>.Continuation

    public init(configuration: Configuration) {
        precondition(configuration.colorResolution.map { $0.width <= 960 && $0.height <= 720 } ?? true,
                     "colour is rendered at 960 × 720 or smaller")
        self.configuration = configuration
        raycaster = Raycaster(model: configuration.room)
        camera = VirtualCamera(path: configuration.path, configuration: configuration.camera)
        chunker = AnchorChunker(model: configuration.room, configuration: configuration.chunker)
        (sampleStream, sampleContinuation) = AsyncStream.makeStream(of: CameraSample.self)
        (anchorStream, anchorContinuation) = AsyncStream.makeStream(of: AnchorEvent.self)
    }

    public convenience init(seed: UInt64) {
        self.init(configuration: Configuration(seed: seed))
    }

    // MARK: CaptureSource

    public var isAvailable: Bool { true }
    public var cameraAuthorized: Bool { true }
    public var samples: AsyncStream<CameraSample> { sampleStream }
    public var anchorEvents: AsyncStream<AnchorEvent> { anchorStream }

    public func start() throws {
        let shouldRun: Bool = lock.withLock {
            guard state == .idle else { return false }
            state = .running
            return true
        }
        guard shouldRun else { return }
        if configuration.zeroFrames {
            sampleContinuation.finish()
            anchorContinuation.finish()
            return
        }
        let task = Task.detached(priority: .userInitiated) { [self] in
            await produce()
        }
        lock.withLock { producer = task }
    }

    public func stop() {
        let task: Task<Void, Never>? = lock.withLock {
            state = .stopped
            return producer
        }
        task?.cancel()
        sampleContinuation.finish()
        anchorContinuation.finish()
    }

    /// Every discovered anchor, degraded.
    public func meshSnapshot() -> [MeshAnchorPayload] {
        lock.withLock { chunker.anchors() }.map(configuration.degradation.apply)
    }

    public func makeCaptureView() -> CaptureViewRepresentable { SyntheticCaptureView() }

    /// Phase 3 wires this to the preview; until then there is no screen to hit.
    public func raycast(screenPoint: CGPoint) -> SIMD3<Float>? { nil }

    // MARK: Introspection

    public var anchorBlockCount: Int { lock.withLock { chunker.blockCount } }
    public var discoveredAnchorCount: Int { lock.withLock { chunker.discoveredCount } }

    // MARK: Producer

    private func produce() async {
        let intrinsics = configuration.camera.intrinsics
        let interval = 1 / configuration.camera.frameRate
        let wallStart = Date()
        for index in 0..<camera.tickCount {
            if Task.isCancelled { break }
            if configuration.realTime {
                let due = wallStart.addingTimeInterval(Double(index) * interval)
                let wait = due.timeIntervalSinceNow
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
                if Task.isCancelled { break }
            }
            let tick = camera.tick(index)

            // Discover anchors from what this tick sees.
            let coarse = raycaster.render(cameraToWorld: tick.cameraToWorld, intrinsics: intrinsics,
                                          resolution: configuration.discoveryResolution)
            var events = lock.withLock { chunker.observe(triangleIDs: coarse.triangleIDs) }
            if let closure = configuration.loopClosure, tick.time >= closure.time {
                let apply: Bool = lock.withLock {
                    guard !loopClosureApplied else { return false }
                    loopClosureApplied = true
                    return true
                }
                if apply { events += lock.withLock { chunker.applyLoopClosure(translation: closure.translation) } }
            }
            for event in events {
                anchorContinuation.yield(degraded(event))
            }

            let sample = CameraSample(transform: tick.cameraToWorld, timestamp: tick.timestamp,
                                      trackingState: tick.trackingState) { [self] in
                materialize(tick)
            }
            sampleContinuation.yield(sample)
        }
        sampleContinuation.finish()
        anchorContinuation.finish()
    }

    private func degraded(_ event: AnchorEvent) -> AnchorEvent {
        switch event {
        case .added(let anchor): return .added(configuration.degradation.apply(to: anchor))
        case .updated(let anchor): return .updated(configuration.degradation.apply(to: anchor))
        case .removed: return event
        }
    }

    /// The full-resolution frame for `tick`: depth, confidence and (optionally) colour.
    public func materialize(_ tick: VirtualCamera.Tick) -> FramePayload {
        let intrinsics = configuration.camera.intrinsics
        let frame = raycaster.render(cameraToWorld: tick.cameraToWorld, intrinsics: intrinsics,
                                     resolution: configuration.depthResolution)
        var color: ColorPlanes?
        var imageResolution = intrinsics.imageResolution
        var frameIntrinsics = intrinsics
        if let size = configuration.colorResolution {
            color = Self.classColorImage(frame, size: size, classes: configuration.room.classes)
            imageResolution = size
            frameIntrinsics = intrinsics.scaled(to: size)
        }
        let meta = FrameMeta(index: tick.index, timestamp: tick.timestamp, cameraTransform: tick.cameraToWorld,
                             intrinsics: frameIntrinsics.matrix, imageResolution: imageResolution,
                             depthResolution: configuration.depthResolution, trackingState: tick.trackingState)
        return FramePayload(depth: frame.depthPlane(), confidence: frame.confidencePlane(), color: color, meta: meta)
    }

    /// A flat-shaded BGRA image: each pixel takes the class colour of the triangle under the
    /// nearest depth pixel (black where the ray missed). A lookup, not a second render.
    static func classColorImage(_ frame: Raycaster.Frame, size: PixelSize, classes: [MeshClassification]) -> ColorPlanes? {
        let width = size.width, height = size.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        var palette = [(UInt8, UInt8, UInt8)]()
        for raw in 0...7 { palette.append(CaptureFormat.classificationColor(UInt8(raw))) }
        bytes.withUnsafeMutableBufferPointer { out in
            frame.triangleIDs.withUnsafeBufferPointer { ids in
                for y in 0..<height {
                    let sy = y * frame.height / height
                    for x in 0..<width {
                        let sx = x * frame.width / width
                        let id = ids[sy * frame.width + sx]
                        let d = (y * width + x) * 4
                        if id >= 0 {
                            let (r, g, b) = palette[Int(classes[Int(id)].rawValue)]
                            out[d] = b; out[d + 1] = g; out[d + 2] = r
                        }
                        out[d + 3] = 255
                    }
                }
            }
        }
        let plane = Plane<UInt8>(data: Data(bytes), width: width, height: height, bytesPerRow: width * 4)
        return try? ColorPlanes(pixelFormat: .bgra32, width: width, height: height, planes: [plane])
    }
}

/// The view a `SyntheticCaptureSource` offers. Phase 3 replaces it with a rendered preview.
public final class SyntheticCaptureView: CaptureViewRepresentable {
    public init() {}
}
