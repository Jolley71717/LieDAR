import Foundation
import LieDARSynthetic

/// Everything an adopting app writes between Start and Stop, in one place.
///
/// The engine pulls samples and anchor events from a `CaptureSource`, applies the write gate,
/// materializes only the frames the gate admits, and hands them to a `CaptureRecorder`. On stop
/// it asks the source for its mesh, writes the manifest, and then either publishes the capture to
/// the list or deletes an empty folder. The mesh is asked for rather than taken from the current
/// frame, because on a simulator there is no current frame to take it from.
///
/// Nothing here knows it is talking to a synthetic source. Swap `Scenario.makeSource()` for an
/// ARKit source on a device and this file does not change.
@MainActor
final class CaptureEngine: ObservableObject {
    enum Phase: String {
        case idle, running, finishing, saved, discarded, failed
    }

    @Published private(set) var phase: Phase = .idle
    /// Frames actually written, which is not the number of samples fed: the gate rejects most.
    @Published private(set) var frameCount = 0
    /// Mesh anchors the source currently holds, counting adds and removes as they arrive.
    @Published private(set) var anchorCount = 0
    /// Seconds between the first and the latest sample.
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var message = ""
    /// The capture that was just saved, if any. The detail screen is one tap from here.
    @Published private(set) var saved: SavedCapture?

    let scenario: Scenario
    private let store: CaptureStore

    private var source: SyntheticCaptureSource?
    private var recorder: CaptureRecorder?
    private var folderURL: URL?
    private var run: Task<Void, Never>?

    private var samplesSeen = 0
    private var normalSamples = 0
    private var firstTimestamp: TimeInterval?
    private var lastTimestamp: TimeInterval?

    init(scenario: Scenario, store: CaptureStore) {
        self.scenario = scenario
        self.store = store
    }

    var isRunning: Bool { phase == .running }
    var isFinished: Bool { phase == .saved || phase == .discarded || phase == .failed }

    func start() {
        guard phase == .idle else { return }
        let folder = store.newCaptureFolder()
        do {
            let recorder = try CaptureRecorder(
                folderURL: folder,
                options: CaptureRecorder.Options(saveColorImages: false, maxPendingFrames: 16))
            let source = scenario.makeSource()
            self.recorder = recorder
            self.source = source
            folderURL = folder
            phase = .running
            message = "Capturing"
            try source.start()
            run = Task { [weak self] in await self?.consume(source: source, recorder: recorder) }
        } catch {
            fail(error)
        }
    }

    /// Stops the source, drains the run, writes the mesh and the manifest, then saves or discards.
    func stopAndSave() async {
        guard phase == .running else { return }
        phase = .finishing
        message = "Writing"
        source?.stop()
        await run?.value
        run = nil
        guard let recorder, let source, let folder = folderURL else {
            fail(EngineError.notStarted)
            return
        }
        do {
            // Degrading and copying every anchor is real work; keep it off the main actor.
            let snapshot = await Task.detached(priority: .userInitiated) { source.meshSnapshot() }.value
            let mesh = try await recorder.writeMeshSnapshot(snapshot)
            let started = Date()
            let manifest = CaptureManifest(
                deviceModel: "LieDAR-synthetic",
                iosVersion: "synthetic",
                startedAt: started,
                endedAt: started.addingTimeInterval(max(1, elapsed.rounded(.up))),
                frameCount: frameCount,
                meshAnchorCount: mesh.anchorCount,
                totalVertices: mesh.totalVertices,
                totalFaces: mesh.totalFaces,
                worldMapSaved: false,
                notes: "scenario: \(scenario.rawValue)",
                normalTrackingFrameCount: normalSamples,
                totalTrackingFrameCount: samplesSeen)
            try await recorder.finish(manifest: manifest)
            if let failure = recorder.frameWriteFailure {
                fail(EngineError.frameWrite(failure.message, failure.count))
                return
            }
            publish(folder: folder)
        } catch {
            fail(error)
        }
    }

    /// Keep a capture that has something in it; delete one that has nothing. An empty folder in
    /// the list is the bug this decides against.
    private func publish(folder: URL) {
        let contents = CaptureFormat.contents(of: folder)
        guard CaptureFormat.disposition(of: contents) != .discardEmpty else {
            try? FileManager.default.removeItem(at: folder)
            phase = .discarded
            message = "Nothing captured, so nothing saved"
            return
        }
        let capture = SavedCapture(id: folder.lastPathComponent,
                                   folderURL: folder,
                                   byteCount: CaptureStore.byteCount(of: folder),
                                   frameCount: contents.frameCount,
                                   anchorCount: contents.meshAnchorCount)
        store.add(capture)
        saved = capture
        phase = .saved
        message = "Saved \(capture.id)"
    }

    /// Abandons a run in progress and leaves nothing behind.
    func cancel() {
        source?.stop()
        run?.cancel()
        run = nil
        if let folderURL { try? FileManager.default.removeItem(at: folderURL) }
        phase = .idle
        message = ""
    }

    // MARK: The capture loop

    private func consume(source: SyntheticCaptureSource, recorder: CaptureRecorder) async {
        let anchors = Task { @MainActor [weak self] in
            for await event in source.anchorEvents {
                guard let self else { return }
                switch event {
                case .added: anchorCount += 1
                case .removed: anchorCount = max(0, anchorCount - 1)
                case .updated: break
                }
            }
        }
        var gate = FrameGate()
        for await sample in source.samples {
            samplesSeen += 1
            if firstTimestamp == nil { firstTimestamp = sample.timestamp }
            lastTimestamp = sample.timestamp
            elapsed = (lastTimestamp ?? 0) - (firstTimestamp ?? 0)
            if sample.trackingState.isNormal { normalSamples += 1 }
            guard gate.admit(sample) else { continue }
            // Raycasting a 256 × 192 frame takes milliseconds. Off the main actor it goes.
            let materialize = sample.materialize
            guard var frame = await Task.detached(priority: .userInitiated, operation: { materialize() }).value else {
                continue
            }
            frame.meta.index = frameCount
            if recorder.write(frame) {
                frameCount += 1
                continue
            }
            // The recorder is full. This is not a real-time consumer, so wait for the disk
            // rather than lose the frame.
            for _ in 0..<500 where recorder.pendingFrameCount > 0 {
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
            if recorder.write(frame) { frameCount += 1 }
        }
        await anchors.value
    }

    private func fail(_ error: Error) {
        phase = .failed
        message = "Failed: \(error)"
    }

    enum EngineError: Error, CustomStringConvertible {
        case notStarted
        case frameWrite(String, Int)

        var description: String {
            switch self {
            case .notStarted: return "capture was never started"
            case .frameWrite(let message, let count): return "\(count) frame(s) failed to write: \(message)"
            }
        }
    }
}
