import Foundation

/// The three streams a live `CaptureSource` vends, and the open/close lifecycle around them.
///
/// This exists so the stream bookkeeping is not inside `ARKitCaptureSource`, where no test on a
/// Mac or a Simulator could reach it (RT-2). Opening, closing, the buffering policy and the rule
/// that a value yielded outside an open window is dropped are all provable on macOS; what is
/// left in the ARKit source is the part that genuinely needs a phone.
///
/// Lifecycle: the streams read before the first `open()`, and after any `close()`, are already
/// finished, so a consumer's `for await` loop ends rather than hanging. `open()` finishes any
/// previous trio and hands out a fresh one, so a second capture is not fed into the first
/// capture's loop.
///
/// Concurrency invariant (why `@unchecked Sendable`): every stored property is touched only
/// inside `lock.withLock`, and `AsyncStream.Continuation` is documented as safe to call from any
/// thread.
public final class CaptureStreams: @unchecked Sendable {
    /// How many samples to hold for a consumer that has fallen behind.
    ///
    /// One, by default, and that number is load-bearing on ARKit. A `CameraSample` retains the
    /// `ARFrame` its `materialize()` closure reads, and ARKit stops delivering frames when too
    /// many are held, so the buffer is what bounds how many frames are alive at once. A consumer
    /// that falls behind sees the newest frame and misses the ones in between, which is what
    /// ARKit does to a slow delegate anyway.
    public let sampleBufferSize: Int

    private let lock = NSLock()
    private var storedSamples: AsyncStream<CameraSample> = .finished
    private var storedAnchorEvents: AsyncStream<AnchorEvent> = .finished
    private var storedSessionEvents: AsyncStream<CaptureSessionEvent> = .finished
    private var sampleContinuation: AsyncStream<CameraSample>.Continuation?
    private var anchorContinuation: AsyncStream<AnchorEvent>.Continuation?
    private var sessionContinuation: AsyncStream<CaptureSessionEvent>.Continuation?

    public init(sampleBufferSize: Int = 1) {
        precondition(sampleBufferSize >= 1, "a sample buffer holds at least one frame")
        self.sampleBufferSize = sampleBufferSize
    }

    /// One value per camera frame.
    public var samples: AsyncStream<CameraSample> { lock.withLock { storedSamples } }
    /// Mesh anchors coming and going. Unbounded: bookkeeping must not miss a removal.
    public var anchorEvents: AsyncStream<AnchorEvent> { lock.withLock { storedAnchorEvents } }
    /// Failures and interruptions. Unbounded and rare.
    public var sessionEvents: AsyncStream<CaptureSessionEvent> { lock.withLock { storedSessionEvents } }

    /// Whether values yielded now reach a consumer.
    public var isOpen: Bool { lock.withLock { sampleContinuation != nil } }

    /// Finishes any open trio and replaces it with a fresh one.
    public func open() {
        let previous = takeContinuations()
        finish(previous)
        let policy = AsyncStream<CameraSample>.Continuation.BufferingPolicy.bufferingNewest(sampleBufferSize)
        let (samples, sampleContinuation) = AsyncStream.makeStream(of: CameraSample.self, bufferingPolicy: policy)
        let (anchors, anchorContinuation) = AsyncStream.makeStream(of: AnchorEvent.self)
        let (events, sessionContinuation) = AsyncStream.makeStream(of: CaptureSessionEvent.self)
        lock.withLock {
            storedSamples = samples
            storedAnchorEvents = anchors
            storedSessionEvents = events
            self.sampleContinuation = sampleContinuation
            self.anchorContinuation = anchorContinuation
            self.sessionContinuation = sessionContinuation
        }
    }

    /// Finishes all three streams. Reading them afterwards gives finished streams, and yielding
    /// afterwards does nothing. Calling it twice is harmless.
    public func close() {
        let open = takeContinuations()
        finish(open)
        lock.withLock {
            storedSamples = .finished
            storedAnchorEvents = .finished
            storedSessionEvents = .finished
        }
    }

    /// Hands a frame to the consumer. Returns `false` when the streams are closed, which is the
    /// case for a delegate callback that arrives after `stop()`.
    @discardableResult
    public func yield(_ sample: CameraSample) -> Bool {
        lock.withLock {
            guard let continuation = sampleContinuation else { return false }
            continuation.yield(sample)
            return true
        }
    }

    /// Hands an anchor change to the consumer. Returns `false` when the streams are closed.
    @discardableResult
    public func yield(_ event: AnchorEvent) -> Bool {
        lock.withLock {
            guard let continuation = anchorContinuation else { return false }
            continuation.yield(event)
            return true
        }
    }

    /// Hands a session failure or interruption to the consumer. Returns `false` when the streams
    /// are closed.
    @discardableResult
    public func yield(_ event: CaptureSessionEvent) -> Bool {
        lock.withLock {
            guard let continuation = sessionContinuation else { return false }
            continuation.yield(event)
            return true
        }
    }

    private struct Continuations {
        var samples: AsyncStream<CameraSample>.Continuation?
        var anchors: AsyncStream<AnchorEvent>.Continuation?
        var events: AsyncStream<CaptureSessionEvent>.Continuation?
    }

    /// Clears the continuations under the lock and returns them, so `finish` runs outside it.
    private func takeContinuations() -> Continuations {
        lock.withLock {
            let taken = Continuations(samples: sampleContinuation, anchors: anchorContinuation, events: sessionContinuation)
            sampleContinuation = nil
            anchorContinuation = nil
            sessionContinuation = nil
            return taken
        }
    }

    private func finish(_ continuations: Continuations) {
        continuations.samples?.finish()
        continuations.anchors?.finish()
        continuations.events?.finish()
    }
}
