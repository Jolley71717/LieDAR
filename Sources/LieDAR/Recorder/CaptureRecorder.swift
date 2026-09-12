import Foundation

/// Writes a capture folder in `CaptureFormat` from `FramePayload` / `MeshAnchorPayload` values.
///
/// All file I/O runs on one private serial queue. `write(_:)` is non-blocking: it takes the
/// frame, which is already a plain value so nothing has to be copied under a lock, and returns whether
/// the frame was accepted. At most `Options.maxPendingFrames` frames may be queued; a frame
/// offered past that is **dropped**, `write` returns `false`, and `droppedFrameCount` goes up.
/// That is the backpressure rule: a slow disk costs frames, not memory or latency.
///
/// Writes are atomic per file and a frame's `.json` is written last, so a reader treats the
/// `.json` as the completeness marker (`CaptureReader.FrameStatus.isComplete`). `finish(manifest:)`
/// runs behind every queued write and then writes `capture.json`, the folder-level marker.
///
/// Failures on the queue cannot be thrown to the caller of `write`; they are collected in
/// `frameWriteFailure` for the owner to surface after `finish`.
///
/// Concurrency invariant (why `@unchecked Sendable`): the class is a reference shared between
/// the caller's context and the writer queue, so the compiler cannot prove it. Every mutable
/// stored property (`pendingFrames`, `acceptedFrames`, `droppedFrames`, `failedFrames`,
/// `firstFrameFailure`, `isFinished`, `meshSnapshotWritten`) is touched only inside
/// `lock.withLock`; `queue` and the URLs/options are immutable; file-system state is touched
/// only on `queue`. Nothing else may be added to the class without joining one of those rules.
public final class CaptureRecorder: @unchecked Sendable {
    public struct Options: Sendable, Equatable {
        /// Write `frames/NNNNNN.jpg` when the frame carries colour.
        public var saveColorImages = true
        /// Colour images are downscaled so the long edge is at most this many pixels.
        public var colorImageMaxLongEdge = 640
        /// JPEG quality 0…1.
        public var colorImageJPEGQuality = 0.6
        /// Frames offered while this many are still being written are dropped.
        public var maxPendingFrames = 6

        public init(saveColorImages: Bool = true, colorImageMaxLongEdge: Int = 640,
                    colorImageJPEGQuality: Double = 0.6, maxPendingFrames: Int = 6) {
            self.saveColorImages = saveColorImages
            self.colorImageMaxLongEdge = colorImageMaxLongEdge
            self.colorImageJPEGQuality = colorImageJPEGQuality
            self.maxPendingFrames = maxPendingFrames
        }
    }

    /// The first frame-write failure and how many frames have failed so far.
    public struct FrameWriteFailure: Sendable, Equatable {
        public var message: String
        public var count: Int
    }

    public enum RecorderError: Error, Equatable, Sendable {
        case finished
        case meshLayout(anchor: UUID, detail: String)
    }

    public let folderURL: URL
    public let framesURL: URL
    public let meshURL: URL
    public let options: Options

    private let queue = DispatchQueue(label: "LieDAR.CaptureRecorder", qos: .userInitiated)
    private let lock = NSLock()
    // Guarded by `lock`.
    private var pendingFrames = 0
    private var acceptedFrames = 0
    private var droppedFrames = 0
    private var failedFrames = 0
    private var firstFrameFailure: String?
    private var isFinished = false
    private var meshSnapshotWritten = false

    /// Creates `frames/` and `mesh/` under `folderURL` (and the folder itself).
    public init(folderURL: URL, options: Options = Options()) throws {
        self.folderURL = folderURL
        self.options = options
        framesURL = folderURL.appendingPathComponent(CaptureFormat.framesDirectory, isDirectory: true)
        meshURL = folderURL.appendingPathComponent(CaptureFormat.meshDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: framesURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: meshURL, withIntermediateDirectories: true)
    }

    // MARK: Counters

    /// Frames accepted by `write(_:)` so far (queued or already on disk).
    public var acceptedFrameCount: Int { lock.withLock { acceptedFrames } }
    /// Frames refused by `write(_:)` because `maxPendingFrames` were still in flight.
    public var droppedFrameCount: Int { lock.withLock { droppedFrames } }
    /// Frames accepted but not yet on disk.
    public var pendingFrameCount: Int { lock.withLock { pendingFrames } }

    /// Non-nil once any frame's files failed to write. Read after `finish(manifest:)`.
    public var frameWriteFailure: FrameWriteFailure? {
        lock.withLock {
            guard let firstFrameFailure else { return nil }
            return FrameWriteFailure(message: firstFrameFailure, count: failedFrames)
        }
    }

    // MARK: Frames

    /// Queues the frame's files for writing under `frame.meta.index`. Returns `false`, and
    /// counts a drop, when `maxPendingFrames` frames are still in flight or the recorder has
    /// finished. Callers that number frames themselves should only advance on `true`.
    @discardableResult
    public func write(_ frame: FramePayload) -> Bool {
        let accepted: Bool = lock.withLock {
            if isFinished || pendingFrames >= self.options.maxPendingFrames {
                droppedFrames += 1
                return false
            }
            pendingFrames += 1
            acceptedFrames += 1
            return true
        }
        guard accepted else { return false }

        queue.async { [self] in
            defer { lock.withLock { pendingFrames -= 1 } }
            let index = frame.meta.index
            let base = CaptureFormat.frameBaseName(index)
            do {
                try frame.depth.tightlyPacked().write(to: frameURL(base, CaptureFormat.depthExtension), options: .atomic)
                if let confidence = frame.confidence {
                    try confidence.tightlyPacked().write(to: frameURL(base, CaptureFormat.confidenceExtension), options: .atomic)
                }
                if options.saveColorImages, let color = frame.color {
                    let jpeg = try JPEGEncoder.encode(color, maxLongEdge: options.colorImageMaxLongEdge,
                                                      quality: options.colorImageJPEGQuality)
                    try jpeg.write(to: frameURL(base, CaptureFormat.colorExtension), options: .atomic)
                }
                // JSON last: its presence marks the frame as complete.
                try CaptureFormat.makeJSONEncoder().encode(frame.meta)
                    .write(to: frameURL(base, CaptureFormat.frameMetaExtension), options: .atomic)
            } catch {
                lock.withLock {
                    failedFrames += 1
                    if firstFrameFailure == nil { firstFrameFailure = "frame \(index): \(error.localizedDescription)" }
                }
            }
        }
        return true
    }

    private func frameURL(_ base: String, _ ext: String) -> URL {
        framesURL.appendingPathComponent(base).appendingPathExtension(ext)
    }

    // MARK: Mesh

    /// Writes every anchor's three binaries, `mesh/anchors.json` and the merged `mesh.ply`,
    /// behind any frames still queued. Anchors are written in the order given; `anchors.json`
    /// lists them in that order. Every anchor is validated before any file is written, so an
    /// anchor whose buffers disagree with its counts throws and leaves `mesh/` untouched.
    public func writeMeshSnapshot(_ anchors: [MeshAnchorPayload]) async throws -> MeshSnapshotSummary {
        try await onQueue { try self.writeMeshSnapshotSync(anchors) }
    }

    private func writeMeshSnapshotSync(_ anchors: [MeshAnchorPayload]) throws -> MeshSnapshotSummary {
        for anchor in anchors {
            do {
                try anchor.validate()
            } catch {
                throw RecorderError.meshLayout(anchor: anchor.id, detail: String(describing: error))
            }
        }

        var metas: [MeshAnchorMeta] = []
        var summary = MeshSnapshotSummary()
        var ply = PLYBuilder()

        for anchor in anchors {
            let meta = MeshAnchorMeta(anchor)
            try anchor.vertices.write(to: meshURL.appendingPathComponent(meta.verticesFile), options: .atomic)
            try anchor.faces.write(to: meshURL.appendingPathComponent(meta.facesFile), options: .atomic)
            try anchor.classes.write(to: meshURL.appendingPathComponent(meta.classesFile), options: .atomic)
            metas.append(meta)
            ply.append(anchor)

            summary.anchorCount += 1
            summary.totalVertices += anchor.vertexCount
            summary.totalFaces += anchor.faceCount
        }

        try CaptureFormat.makeJSONEncoder().encode(metas)
            .write(to: meshURL.appendingPathComponent(CaptureFormat.anchorsFile), options: .atomic)
        try Data(ply.render().utf8)
            .write(to: folderURL.appendingPathComponent(CaptureFormat.mergedPLYFile), options: .atomic)
        lock.withLock { meshSnapshotWritten = true }
        return summary
    }

    // MARK: Manifest

    /// Waits for every queued frame write, then writes `capture.json`. If `writeMeshSnapshot`
    /// was never called, an empty snapshot (`mesh/anchors.json` as `[]`, `mesh.ply` with zero
    /// elements) is written first so a finished folder always has the same shape. After this,
    /// `write(_:)` drops every frame. Calling it twice throws `RecorderError.finished`.
    public func finish(manifest: CaptureManifest) async throws {
        let alreadyFinished: Bool = lock.withLock {
            defer { isFinished = true }
            return isFinished
        }
        guard !alreadyFinished else { throw RecorderError.finished }
        try await onQueue {
            if !self.lock.withLock({ self.meshSnapshotWritten }) {
                _ = try self.writeMeshSnapshotSync([])
            }
            try CaptureFormat.makeJSONEncoder().encode(manifest)
                .write(to: self.folderURL.appendingPathComponent(CaptureFormat.manifestFile), options: .atomic)
        }
    }

    // MARK: Queue

    /// Runs `body` on the writer queue behind everything already queued. Exposed for tests,
    /// which use it to hold the queue and prove the backpressure rule.
    func enqueue(_ body: @escaping @Sendable () -> Void) {
        queue.async(execute: body)
    }

    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try body())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
