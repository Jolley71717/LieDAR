import Foundation

/// Runs any `CaptureSource` through a `FrameGate` into a `CaptureRecorder` until its streams
/// finish, then writes the mesh snapshot and the manifest. This is the whole of what a capture
/// session does between Start and Stop, in the package, so a fixture generator and an
/// end-to-end test exercise the same path. The report carries counts, not presence.
public enum ScriptedCapture {
    public struct Options: Sendable {
        public var gate = FrameGate()
        public var recorder = CaptureRecorder.Options(saveColorImages: false, maxPendingFrames: 16)
        /// Written to `capture.json`; never a real model or OS string.
        public var deviceModel = "LieDAR-synthetic"
        public var iosVersion = "synthetic"
        /// A fixed start so a generated capture is byte-for-byte reproducible.
        public var startedAt = Date(timeIntervalSince1970: 1_767_225_600)  // 2026-01-01T00:00:00Z
        public var notes = ""

        public init() {}
    }

    public struct Report: Sendable, Equatable {
        public var samplesSeen = 0
        public var normalSamples = 0
        public var framesAdmitted = 0
        public var framesWritten = 0
        public var framesDropped = 0
        public var anchorsAdded = 0
        public var anchorsUpdated = 0
        public var anchorsRemoved = 0
        public var mesh = MeshSnapshotSummary()
        public var firstTimestamp: TimeInterval?
        public var lastTimestamp: TimeInterval?

        public init() {}
    }

    /// Starts `source`, consumes it to the end, writes the folder, stops it.
    public static func record(from source: some CaptureSource, to folder: URL, options: Options = Options()) async throws -> Report {
        let recorder = try CaptureRecorder(folderURL: folder, options: options.recorder)
        try source.start()
        defer { source.stop() }

        var report = Report()
        var gate = options.gate

        let anchorCounts = Task<(Int, Int, Int), Never> {
            var added = 0, updated = 0, removed = 0
            for await event in source.anchorEvents {
                switch event {
                case .added: added += 1
                case .updated: updated += 1
                case .removed: removed += 1
                }
            }
            return (added, updated, removed)
        }

        for await sample in source.samples {
            report.samplesSeen += 1
            if report.firstTimestamp == nil { report.firstTimestamp = sample.timestamp }
            report.lastTimestamp = sample.timestamp
            if sample.trackingState.isNormal { report.normalSamples += 1 }
            guard gate.admit(sample) else { continue }
            report.framesAdmitted += 1
            guard var frame = sample.materialize() else { continue }
            frame.meta.index = report.framesWritten
            if recorder.write(frame) {
                report.framesWritten += 1
                continue
            }
            // Not a real-time consumer: wait for the disk rather than lose the frame.
            for _ in 0..<500 where recorder.pendingFrameCount > 0 {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            if recorder.write(frame) {
                report.framesWritten += 1
            } else {
                report.framesDropped += 1
            }
        }
        (report.anchorsAdded, report.anchorsUpdated, report.anchorsRemoved) = await anchorCounts.value

        let anchors = source.meshSnapshot()
        report.mesh = try await recorder.writeMeshSnapshot(anchors)
        let elapsed = (report.lastTimestamp ?? 0) - (report.firstTimestamp ?? 0)
        let manifest = CaptureManifest(deviceModel: options.deviceModel,
                                       iosVersion: options.iosVersion,
                                       startedAt: options.startedAt,
                                       endedAt: options.startedAt.addingTimeInterval(max(1, elapsed.rounded(.up))),
                                       frameCount: report.framesWritten,
                                       meshAnchorCount: report.mesh.anchorCount,
                                       totalVertices: report.mesh.totalVertices,
                                       totalFaces: report.mesh.totalFaces,
                                       worldMapSaved: false,
                                       notes: options.notes,
                                       normalTrackingFrameCount: report.normalSamples,
                                       totalTrackingFrameCount: report.samplesSeen)
        try await recorder.finish(manifest: manifest)
        if let failure = recorder.frameWriteFailure {
            throw CaptureError.frameWriteFailed(failure.message, count: failure.count)
        }
        return report
    }

    public enum CaptureError: Error, Equatable, Sendable {
        case frameWriteFailed(String, count: Int)
    }
}
