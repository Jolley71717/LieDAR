import Combine
import Foundation
import SwiftUI
import simd

/// Holds what is held down and advances a `Walker` while it is, then hands the pose somewhere.
///
/// This is the wiring between the controls on screen and the state machine underneath. It owns
/// no rules of its own: which key does what is `WalkInput`, what a held control does to the
/// camera is `Walker`, and what happens to the resulting pose is `onPose`. The split is what
/// lets the rules be tested without a screen.
@MainActor public final class WalkDriver: ObservableObject {
    /// Where the camera is and what it is looking at.
    @Published public var walker: Walker
    /// Which controls are down right now.
    @Published public private(set) var held: WalkInput = []

    /// Called with a new camera-to-world every time the walker moves. Set by `drive(_:)`, or by
    /// a host that wants the pose for something else.
    public var onPose: ((simd_float4x4) -> Void)?
    /// How often the held controls are applied, in hertz.
    public var tickRate: Double = 60

    private var loop: Task<Void, Never>?
    private var lastTick: Date?

    public init(walker: Walker) {
        self.walker = walker
    }

    /// A driver standing where `source`'s scripted path starts, looking where it looks, kept
    /// inside the room's bounding box, and handing every pose back to the source so the frames
    /// it renders come from where the person walked. Call `source.drivenPose = nil` to give the
    /// camera back to the script.
    public convenience init(driving source: SyntheticCaptureSource) {
        let start = source.configuration.path.sample(at: 0)
        self.init(walker: .looking(from: start.position, at: start.lookAt,
                                  bounds: .box(of: source.configuration.room)))
        drive(source)
    }

    deinit {
        loop?.cancel()
    }

    /// Sends every pose to `source`, and sends the current one now.
    public func drive(_ source: SyntheticCaptureSource) {
        onPose = { source.drivenPose = $0 }
        onPose?(walker.cameraToWorld)
    }

    // MARK: Input

    public func press(_ input: WalkInput) {
        held.insert(input)
    }

    public func release(_ input: WalkInput) {
        held.remove(input)
    }

    /// Lets go of everything, for a view that lost focus with keys down.
    public func releaseAll() {
        held = []
    }

    // MARK: Loop

    /// Begins applying whatever is held. Calling it twice does nothing the second time.
    public func start() {
        guard loop == nil else { return }
        lastTick = Date()
        let interval = UInt64(1e9 / max(1, tickRate))
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.step()
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        lastTick = nil
        releaseAll()
    }

    /// Advances by the time since the last step. Real elapsed time rather than the nominal
    /// interval, so a busy main thread slows the walk down instead of losing it.
    func step() {
        let now = Date()
        let elapsed = min(0.1, now.timeIntervalSince(lastTick ?? now))
        lastTick = now
        guard !held.isEmpty else { return }
        walker.apply(held, for: elapsed)
        onPose?(walker.cameraToWorld)
    }
}
