// The guard is `canImport(ARKit) && os(iOS)`, not `canImport(ARKit)` on its own.
//
// The macOS SDK ships an ARKit.framework, so `canImport(ARKit)` is true on a Mac and this file
// was compiled there, where `ARSession`, `ARFrame` and `ARAnchor` do not exist. Measured on
// Xcode 26.5 with the macOS 26.5 SDK: `swift build` reported "cannot find type 'ARSession' in
// scope" 11 times. `os(iOS)` is what actually names the platform the session API is on, and
// Mac Catalyst is excluded because `ARWorldTrackingConfiguration` is not available there either.
// Not `targetEnvironment(simulator)`: this source belongs on a Simulator build too, where it
// compiles, reports itself unavailable and lets a synthetic source take over (RT-10).
#if canImport(ARKit) && os(iOS) && !targetEnvironment(macCatalyst)
import ARKit
import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import LieDAR
import RealityKit
import os
import simd

/// The `CaptureSource` backed by real hardware: one `ARSession`, its delegate, the `ARView` that
/// shows the camera feed, and the raycast that puts an annotation on a surface. Every ARKit type
/// this package touches is touched here and nowhere else, which is the point of the type. The
/// synthetic and replay sources are peers of this one, not special cases of it.
///
/// ## What this deliberately does not hold
///
/// Stream lifecycle is `CaptureStreams`, anchor bookkeeping is `AnchorTable`, and the pointer
/// work behind every copy is `BufferCopy`. All three live in the `LieDAR` core module, where a
/// test on a Mac can reach them. That is finding RT-2: the logic worth testing does not belong
/// on the far side of a framework that only runs on a phone.
///
/// ## Why `isAvailable` is asked of the source
///
/// `ARWorldTrackingConfiguration.supportsSceneReconstruction` is a static query that is false on
/// every Simulator whatever the source could actually do, so a consumer that calls it directly
/// can never enable Start under a synthetic or replayed capture. Ask the source instead. This is
/// finding RT-1, and this property is the only place in the package that runs that query.
///
/// ## What only a device can prove
///
/// ARKit delivers no frames on the Simulator and `ARFrame`, `ARMeshAnchor` and `ARMeshGeometry`
/// have no public initialisers, so nothing that consumes them can be exercised by a unit test on
/// any machine here. `docs/ARKIT_SOURCE.md` lists what a person has to run on a phone and what
/// they should see. What is tested on a Mac and a Simulator: the conformance compiles, this type
/// reports unavailable where scene reconstruction is, `start()` refuses to run there,
/// `cameraAuthorized` follows the authorization status, the streams are finished before `start()`
/// and after `stop()`, and every helper named above.
///
/// ## Concurrency
///
/// `CaptureSource` is `Sendable` and its members are not actor-isolated, while `ARView` is
/// main-actor. The stored properties here are touched only inside `lock.withLock`, which is what
/// `@unchecked Sendable` is asserting; the two members that touch the view hop to the main actor
/// with `MainActor.assumeIsolated`, so calling them off the main thread traps loudly instead of
/// racing quietly. ARKit delivers its delegate callbacks on the main queue when `delegateQueue`
/// is nil, which is the case here.
public final class ARKitCaptureSource: NSObject, CaptureSource, ARSessionDelegate, @unchecked Sendable {
    /// What to ask ARKit for. Fixed at init, because changing it under a running session would
    /// mean a reconfigure that the capture format has no way to describe.
    public struct Configuration: Sendable {
        /// Ask for per-face classification with the mesh. A device that cannot classify still
        /// reconstructs geometry, and every face then reads `MeshClassification.none`.
        public var classifiesMesh: Bool
        /// Detect horizontal and vertical planes. `raycast(screenPoint:)` hits an estimated
        /// plane long before the reconstructed mesh has filled in, so annotation placement
        /// works from the first second of a capture.
        public var detectsPlanes: Bool
        /// Copy the colour image into each materialized frame. Off makes `FramePayload.color`
        /// nil and saves the largest copy in the frame.
        public var capturesColor: Bool
        /// Frames held for a consumer that has fallen behind. One by default: a `CameraSample`
        /// retains its `ARFrame`, and ARKit stops delivering when too many are held.
        public var sampleBufferSize: Int

        public init(classifiesMesh: Bool = true, detectsPlanes: Bool = true,
                    capturesColor: Bool = true, sampleBufferSize: Int = 1) {
            self.classifiesMesh = classifiesMesh
            self.detectsPlanes = detectsPlanes
            self.capturesColor = capturesColor
            self.sampleBufferSize = sampleBufferSize
        }
    }

    private static let logger = Logger(subsystem: "com.jolleytech.liedar", category: "ARKitCaptureSource")

    public let configuration: Configuration

    private let streams: CaptureStreams
    private let lock = NSLock()
    private var storedSession: ARSession?
    private var storedView: ARView?
    private var anchors = AnchorTable()

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        streams = CaptureStreams(sampleBufferSize: configuration.sampleBufferSize)
        super.init()
    }

    // MARK: Availability

    /// The one place in this package that asks ARKit whether the hardware can reconstruct a
    /// scene (RT-1). False on every Simulator, and on any device without a LiDAR sensor.
    public var isAvailable: Bool {
        let reconstruction: ARConfiguration.SceneReconstruction = configuration.classifiesMesh ? .meshWithClassification : .mesh
        return ARWorldTrackingConfiguration.supportsSceneReconstruction(reconstruction)
            && ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    /// Whether the user has allowed the camera. A capture that starts without this produces no
    /// frames at all, and the reason is worth telling apart from an unsupported device.
    public var cameraAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    // MARK: Streams

    public var samples: AsyncStream<CameraSample> { streams.samples }
    public var anchorEvents: AsyncStream<AnchorEvent> { streams.anchorEvents }
    public var sessionEvents: AsyncStream<CaptureSessionEvent> { streams.sessionEvents }

    // MARK: Lifecycle

    /// Opens the streams and runs the session. Throws `CaptureSourceError.unavailable` where the
    /// hardware cannot reconstruct a scene, and `.cameraNotAuthorized` when the camera has not
    /// been allowed, rather than starting a session that would deliver nothing.
    public func start() throws {
        guard isAvailable else { throw CaptureSourceError.unavailable }
        guard cameraAuthorized else { throw CaptureSourceError.cameraNotAuthorized }

        lock.withLock { anchors.removeAll() }
        streams.open()

        let worldTracking = ARWorldTrackingConfiguration()
        worldTracking.sceneReconstruction = configuration.classifiesMesh ? .meshWithClassification : .mesh
        worldTracking.frameSemantics = [.sceneDepth]
        worldTracking.planeDetection = configuration.detectsPlanes ? [.horizontal, .vertical] : []
        worldTracking.environmentTexturing = .none
        worldTracking.isAutoFocusEnabled = true

        let session = session()
        // An ARView takes the session's delegate when the session is attached to it, so claim it
        // back here rather than only at init.
        session.delegate = self
        session.run(worldTracking, options: [.resetTracking, .removeExistingAnchors, .resetSceneReconstruction])
    }

    /// Pauses the session and finishes the streams. The anchors stay, so `meshSnapshot()` still
    /// answers afterwards, which is what a consumer writing the mesh at stop time needs.
    public func stop() {
        lock.withLock { storedSession }?.pause()
        streams.close()
    }

    // MARK: Snapshot

    /// Every mesh anchor the delegate has reported and not seen removed.
    ///
    /// Read from the table rather than from `session.currentFrame.anchors`, because
    /// `currentFrame` is nil once the session is paused and a consumer asks for the mesh at stop
    /// time. That is the other half of finding RT-2.
    public func meshSnapshot() -> [MeshAnchorPayload] {
        lock.withLock { anchors.snapshot() }
    }

    /// The archived `ARWorldMap`, for relocalizing a later session against this capture. `nil`
    /// when the session has not run, when ARKit declines, or when the archive fails.
    public func worldMapData() async -> Data? {
        guard let session = lock.withLock({ storedSession }) else { return nil }
        return await withCheckedContinuation { continuation in
            session.getCurrentWorldMap { map, error in
                if let error {
                    Self.logger.debug("getCurrentWorldMap failed: \(error.localizedDescription, privacy: .public)")
                }
                guard let map else { return continuation.resume(returning: nil) }
                do {
                    continuation.resume(returning: try NSKeyedArchiver.archivedData(withRootObject: map,
                                                                                    requiringSecureCoding: true))
                } catch {
                    Self.logger.error("could not archive the world map: \(String(describing: error), privacy: .public)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: View

    /// The camera feed with the reconstructed mesh drawn over it, bound to this source's session.
    /// The same view every time it is asked for. Main actor only; the protocol member is not
    /// isolated, so calling this off the main thread traps here rather than racing inside UIKit.
    public func makeCaptureView() -> CaptureViewRepresentable {
        MainActor.assumeIsolated { installViewIfNeeded() }
        guard let view = lock.withLock({ storedView }) else {
            preconditionFailure("the capture view was not installed")
        }
        return view
    }

    /// The world point under `screenPoint` of the capture view, or `nil` when nothing is there.
    /// An estimated plane first, because it is the best guess at a real surface, then a detected
    /// plane's own geometry, then the reconstructed mesh. `nil` before `makeCaptureView()`,
    /// since there is no screen to hit.
    public func raycast(screenPoint: CGPoint) -> SIMD3<Float>? {
        guard lock.withLock({ storedView }) != nil else { return nil }
        return MainActor.assumeIsolated {
            guard let view = lock.withLock({ storedView }) else { return nil }
            if let hit = view.raycast(from: screenPoint, allowing: .estimatedPlane, alignment: .any).first {
                return hit.worldTransform.translation
            }
            if let hit = view.raycast(from: screenPoint, allowing: .existingPlaneGeometry, alignment: .any).first {
                return hit.worldTransform.translation
            }
            if let ray = view.ray(through: screenPoint) {
                let hits = view.scene.raycast(origin: ray.origin, direction: ray.direction, length: 20, query: .nearest)
                if let hit = hits.first { return hit.position }
            }
            return nil
        }
    }

    @MainActor
    private func installViewIfNeeded() {
        if lock.withLock({ storedView }) != nil { return }
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        let session = session()
        view.session = session
        // Collision, so `scene.raycast` can hit the reconstructed mesh where no plane is
        // estimated; occlusion, so a marker behind a wall is behind it on screen.
        view.environment.sceneUnderstanding.options = [.occlusion, .collision]
        view.renderOptions = [
            .disableMotionBlur,
            .disableDepthOfField,
            .disableHDR,
            .disablePersonOcclusion,
            .disableFaceMesh,
            .disableGroundingShadows,
        ]
        // The view claimed the delegate when the session was attached; claim it back.
        session.delegate = self
        lock.withLock { storedView = view }
    }

    /// The session, made on first use so asking a fresh source `isAvailable` costs nothing.
    private func session() -> ARSession {
        lock.withLock {
            if let storedSession { return storedSession }
            let session = ARSession()
            session.delegate = self
            storedSession = session
            return session
        }
    }

    // MARK: ARSessionDelegate

    public func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let camera = frame.camera
        // The frame goes into the sample's closure and nowhere else, so the sample is what keeps
        // ARKit from recycling the buffers under the copy (RT-3). See `RetainedFrame`.
        let retained = RetainedFrame(frame: frame, capturesColor: configuration.capturesColor)
        streams.yield(CameraSample(transform: camera.transform,
                                   timestamp: frame.timestamp,
                                   trackingState: TrackingState(camera.trackingState),
                                   materialize: { retained.payload() }))
    }

    public func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        emit(anchors) { .added($0) }
    }

    public func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        emit(anchors) { .updated($0) }
    }

    public func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        for anchor in anchors where anchor is ARMeshAnchor {
            let event = AnchorEvent.removed(anchor.identifier)
            lock.withLock { self.anchors.apply(event) }
            streams.yield(event)
        }
    }

    public func session(_ session: ARSession, didFailWithError error: Error) {
        streams.yield(CaptureSessionEvent.failed(error.localizedDescription))
    }

    public func sessionWasInterrupted(_ session: ARSession) {
        streams.yield(CaptureSessionEvent.interrupted)
    }

    public func sessionInterruptionEnded(_ session: ARSession) {
        streams.yield(CaptureSessionEvent.interruptionEnded)
    }

    public func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool {
        true
    }

    /// Copies each mesh anchor's geometry here, in the callback, and records it in the table
    /// before handing it on. An `ARMeshAnchor` owns Metal buffers ARKit is free to reuse once
    /// this returns, so a payload built later would read whatever replaced them.
    private func emit(_ incoming: [ARAnchor], as event: (MeshAnchorPayload) -> AnchorEvent) {
        for anchor in incoming {
            guard let mesh = anchor as? ARMeshAnchor else { continue }
            do {
                let payload = try ARKitCaptureSource.payload(from: mesh)
                let change = event(payload)
                lock.withLock { anchors.apply(change) }
                streams.yield(change)
            } catch {
                Self.logger.error("skipping mesh anchor \(mesh.identifier.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }
}

/// An `ARFrame` carried into a `@Sendable` closure, which the compiler cannot check for us
/// because ARKit does not mark `ARFrame` as `Sendable`.
///
/// What makes it safe, and why this is a box rather than a bare capture: `CameraSample` crosses
/// an `AsyncStream`, so its `materialize()` has to be `@Sendable`. The closure retains the frame,
/// and ARKit does not recycle a frame's pixel buffers while it is retained; it stops delivering
/// new frames instead, which is why the sample stream buffers one frame and not many. Nothing
/// writes to the frame after the delegate hands it over, and `payload()` only reads it. That is
/// finding RT-3: the copy has to be made from a frame that is still alive, and the retention is
/// what keeps it alive.
private struct RetainedFrame: @unchecked Sendable {
    let frame: ARFrame
    let capturesColor: Bool

    func payload() -> FramePayload? {
        ARKitCaptureSource.payload(from: frame, capturesColor: capturesColor)
    }
}

// MARK: - Copying out of ARKit

extension ARKitCaptureSource {
    /// What ARKit could not hand over in a shape the format describes.
    public enum ReadError: Error, Equatable, Sendable {
        /// A pixel buffer whose base address could not be read while locked.
        case unreadablePixelBuffer
        /// A vertex buffer that is not three floats per vertex.
        case unexpectedVertexFormat(UInt)
        /// A colour image in a format the capture format has no place for.
        case unsupportedColorFormat(OSType)
    }

    /// Everything the recorder needs from one frame, copied out of the frame's buffers.
    /// `meta.index` is left at 0 for the consumer to stamp. `nil` when the frame carries no
    /// depth, which is every frame before the sensor has settled.
    static func payload(from frame: ARFrame, capturesColor: Bool) -> FramePayload? {
        guard let sceneDepth = frame.sceneDepth else { return nil }
        guard let depth: Plane<Float32> = try? plane(of: sceneDepth.depthMap, as: Float32.self) else {
            Self.logger.error("frame had depth ARKit would not let us read")
            return nil
        }
        let confidence: Plane<UInt8>? = sceneDepth.confidenceMap.flatMap { try? plane(of: $0, as: UInt8.self) }
        let color: ColorPlanes? = capturesColor ? try? colorPlanes(of: frame.capturedImage) : nil

        let camera = frame.camera
        let meta = FrameMeta(index: 0,
                             timestamp: frame.timestamp,
                             cameraTransform: camera.transform,
                             intrinsics: camera.intrinsics,
                             imageResolution: PixelSize(width: Int(camera.imageResolution.width),
                                                        height: Int(camera.imageResolution.height)),
                             depthResolution: PixelSize(width: depth.width, height: depth.height),
                             trackingState: TrackingState(camera.trackingState))
        return FramePayload(depth: depth, confidence: confidence, color: color, meta: meta)
    }

    /// One mesh anchor copied off its Metal buffers into plain bytes.
    static func payload(from anchor: ARMeshAnchor) throws -> MeshAnchorPayload {
        let geometry = anchor.geometry

        let vertexSource = geometry.vertices
        guard vertexSource.format == .float3, vertexSource.componentsPerVector == 3 else {
            throw ReadError.unexpectedVertexFormat(vertexSource.format.rawValue)
        }
        let vertices = try BufferCopy.vertices(from: UnsafeRawPointer(vertexSource.buffer.contents()),
                                               count: vertexSource.count,
                                               stride: vertexSource.stride,
                                               offset: vertexSource.offset)

        let faceSource = geometry.faces
        let faces = try BufferCopy.faceIndices(from: UnsafeRawPointer(faceSource.buffer.contents()),
                                               faceCount: faceSource.count,
                                               indicesPerPrimitive: faceSource.indexCountPerPrimitive,
                                               bytesPerIndex: faceSource.bytesPerIndex)

        var classes = [UInt8](repeating: 0, count: faceSource.count)
        if let classification = geometry.classification {
            classes = BufferCopy.faceClasses(from: UnsafeRawPointer(classification.buffer.contents()),
                                             count: classification.count,
                                             stride: classification.stride,
                                             offset: classification.offset,
                                             faceCount: faceSource.count)
        }

        return MeshAnchorPayload(id: anchor.identifier, transform: anchor.transform,
                                 vertices: vertices, faces: faces, classes: classes)
    }

    /// A tightly packed plane copied out of a single-plane pixel buffer, the buffer locked for
    /// the length of the copy.
    static func plane<Element>(of buffer: CVPixelBuffer, as element: Element.Type) throws -> Plane<Element> {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw ReadError.unreadablePixelBuffer }
        return try BufferCopy.plane(from: base,
                                    width: CVPixelBufferGetWidth(buffer),
                                    height: CVPixelBufferGetHeight(buffer),
                                    bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                    as: Element.self)
    }

    /// The camera image as bytes. ARKit hands over bi-planar 4:2:0 full range; a buffer in
    /// 32-bit BGRA is read too, since a consumer can ask for one.
    static func colorPlanes(of buffer: CVPixelBuffer) throws -> ColorPlanes {
        let type = CVPixelBufferGetPixelFormatType(buffer)
        let format: ColorPlanes.PixelFormat
        switch type {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: format = .yCbCr420BiPlanarFullRange
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: format = .yCbCr420BiPlanarFullRange
        case kCVPixelFormatType_32BGRA: format = .bgra32
        default: throw ReadError.unsupportedColorFormat(type)
        }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        var planes: [Plane<UInt8>] = []
        if CVPixelBufferIsPlanar(buffer) {
            for index in 0..<CVPixelBufferGetPlaneCount(buffer) {
                guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, index) else {
                    throw ReadError.unreadablePixelBuffer
                }
                planes.append(try BufferCopy.colorPlane(from: base,
                                                        width: CVPixelBufferGetWidthOfPlane(buffer, index),
                                                        height: CVPixelBufferGetHeightOfPlane(buffer, index),
                                                        bytesPerPixel: ColorPlanes.bytesPerPixel(format, plane: index),
                                                        bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(buffer, index)))
            }
        } else {
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw ReadError.unreadablePixelBuffer }
            planes.append(try BufferCopy.colorPlane(from: base,
                                                    width: width,
                                                    height: height,
                                                    bytesPerPixel: ColorPlanes.bytesPerPixel(format, plane: 0),
                                                    bytesPerRow: CVPixelBufferGetBytesPerRow(buffer)))
        }
        return try ColorPlanes(pixelFormat: format, width: width, height: height, planes: planes)
    }
}

// MARK: - Tracking state

extension TrackingState {
    /// ARKit's tracking state as the string form the capture format stores. A state a later iOS
    /// adds reads as `.limitedUnknown` or `.unknown` rather than failing.
    public init(_ state: ARCamera.TrackingState) {
        switch state {
        case .normal:
            self = .normal
        case .notAvailable:
            self = .notAvailable
        case .limited(let reason):
            switch reason {
            case .initializing: self = .limitedInitializing
            case .excessiveMotion: self = .limitedExcessiveMotion
            case .insufficientFeatures: self = .limitedInsufficientFeatures
            case .relocalizing: self = .limitedRelocalizing
            @unknown default: self = .limitedUnknown
            }
        @unknown default:
            self = .unknown
        }
    }
}

// MARK: - The view

/// RealityKit's `ARView` is what this source puts on screen, so it is what satisfies the core
/// module's marker protocol. The conformance is here rather than in `LieDAR` because the core
/// module imports no RealityKit, which is what keeps it building on macOS.
extension ARView: CaptureViewRepresentable {}

#endif
