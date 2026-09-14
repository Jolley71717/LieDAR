import Foundation

/// The set of mesh anchors a source is holding, updated by the events it has already sent.
///
/// A live source has to answer `meshSnapshot()` after `stop()` has paused the session, so it
/// cannot fish the anchors back out of the session at that point: on ARKit `currentFrame` is
/// nil once the session is paused, which is half of finding RT-2. Keeping the table means the
/// snapshot is the sum of the events the consumer saw, and it stays right after stop.
///
/// This is also the piece that can be tested on a Mac. Add, replace, remove and the snapshot's
/// order are pure dictionary work with no ARKit in them.
public struct AnchorTable: Sendable, Equatable {
    private var byID: [UUID: MeshAnchorPayload] = [:]

    public init() {}

    /// How many anchors are held.
    public var count: Int { byID.count }

    /// Whether any anchor is held.
    public var isEmpty: Bool { byID.isEmpty }

    /// The anchor with this id, or `nil`.
    public subscript(id: UUID) -> MeshAnchorPayload? { byID[id] }

    /// Applies one event. `.added` and `.updated` both store the payload under its id, because a
    /// reconstruction that re-adds a region under an id already held should leave one anchor,
    /// not two. `.removed` drops it.
    public mutating func apply(_ event: AnchorEvent) {
        switch event {
        case .added(let anchor), .updated(let anchor):
            byID[anchor.id] = anchor
        case .removed(let id):
            byID.removeValue(forKey: id)
        }
    }

    /// Applies events in order.
    public mutating func apply(_ events: [AnchorEvent]) {
        for event in events { apply(event) }
    }

    /// Forgets every anchor.
    public mutating func removeAll() {
        byID.removeAll()
    }

    /// Every anchor held, ordered by id. The order is fixed rather than a dictionary's, so two
    /// runs that saw the same events write `mesh/` and `mesh.ply` in the same order.
    public func snapshot() -> [MeshAnchorPayload] {
        byID.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }
}
