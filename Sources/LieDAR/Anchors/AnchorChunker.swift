import Foundation
import simd

/// Turns a `RoomModel` into mesh anchors the way scene reconstruction would: the room's
/// triangles are pre-chunked into blocks of about a metre on a 3-D grid; a block becomes an
/// anchor (`.added`) once the camera has seen at least `discoveryThreshold` of its triangles,
/// and is re-emitted (`.updated`) with more triangles as more are seen. Blocks overlap their
/// neighbours by `overlapMargin`, so triangles near a block boundary appear in two anchors,
/// which are the duplicates a PLY merge must survive. Occasionally an update is instead a `.removed` of
/// the old id followed by an `.added` under a fresh, seeded UUID (ARKit does this too). A
/// loop-closure event translates every anchor at once.
///
/// Not thread-safe by itself; `SyntheticCaptureSource` owns one under its lock.
public final class AnchorChunker {
    public struct Configuration: Sendable, Equatable {
        /// Block edge in metres.
        public var cellSize: Float = 1.0
        /// A triangle whose bounds come within this of a neighbouring block joins it as well.
        public var overlapMargin: Float = 0.1
        /// The grid is shifted by this fraction of a cell on every axis, so a floor at y = 0 or a
        /// wall at x = 0 sits mid-block rather than on a boundary (where the margin would copy
        /// the whole surface into the block beyond it).
        public var gridOffset: Float = 0.5
        /// Triangles a block needs seen before it is emitted as an anchor.
        public var discoveryThreshold: Int = 4
        /// New triangles seen since the last emission before the anchor is re-emitted.
        public var updateThreshold: Int = 8
        /// Probability that an update is delivered as remove-then-add under a new id.
        public var churnProbability: Double = 0.08
        public var seed: UInt64 = 0

        public init(cellSize: Float = 1.0, overlapMargin: Float = 0.1, discoveryThreshold: Int = 4,
                    updateThreshold: Int = 8, churnProbability: Double = 0.08, seed: UInt64 = 0) {
            self.cellSize = cellSize
            self.overlapMargin = overlapMargin
            self.discoveryThreshold = discoveryThreshold
            self.updateThreshold = updateThreshold
            self.churnProbability = churnProbability
            self.seed = seed
        }
    }

    /// One block of the grid.
    struct Block {
        let key: SIMD3<Int32>
        /// World position of the block's minimum corner; the anchor's origin.
        let origin: SIMD3<Float>
        /// Every triangle assigned to this block (including overlap), ascending.
        let triangles: [Int32]
        var seen: Set<Int32> = []
        var id: UUID?
        var emittedCount = 0
        /// Accumulated loop-closure translation.
        var shift = SIMD3<Float>(repeating: 0)
    }

    public let model: RoomModel
    public let configuration: Configuration
    private(set) var blocks: [Block]
    private var blockOfTriangle: [[Int]]
    private var rng: SeededRandom

    public init(model: RoomModel, configuration: Configuration = Configuration()) {
        self.model = model
        self.configuration = configuration
        rng = SeededRandom(seed: configuration.seed, label: 0x616E_6368) // "anch"

        let cell = configuration.cellSize, margin = configuration.overlapMargin
        let shift = configuration.gridOffset * cell
        var membership: [SIMD3<Int32>: [Int32]] = [:]
        var perTriangle = [[Int]](repeating: [], count: model.triangleCount)
        for id in 0..<model.triangleCount {
            let (a, b, c) = model.corners(of: id)
            let lo = simd_min(simd_min(a, b), c) - margin + shift
            let hi = simd_max(simd_max(a, b), c) + margin + shift
            let klo = SIMD3<Int32>(Int32((lo.x / cell).rounded(.down)), Int32((lo.y / cell).rounded(.down)), Int32((lo.z / cell).rounded(.down)))
            let khi = SIMD3<Int32>(Int32((hi.x / cell).rounded(.down)), Int32((hi.y / cell).rounded(.down)), Int32((hi.z / cell).rounded(.down)))
            for kx in klo.x...khi.x {
                for ky in klo.y...khi.y {
                    for kz in klo.z...khi.z {
                        membership[SIMD3(kx, ky, kz), default: []].append(Int32(id))
                    }
                }
            }
        }
        let keys = membership.keys.sorted { a, b in
            a.x != b.x ? a.x < b.x : (a.y != b.y ? a.y < b.y : a.z < b.z)
        }
        var blocks: [Block] = []
        for key in keys {
            let origin = SIMD3<Float>(Float(key.x), Float(key.y), Float(key.z)) * cell - shift
            let triangles = membership[key]!
            for t in triangles { perTriangle[Int(t)].append(blocks.count) }
            blocks.append(Block(key: key, origin: origin, triangles: triangles))
        }
        self.blocks = blocks
        blockOfTriangle = perTriangle
    }

    /// Blocks the grid was split into.
    public var blockCount: Int { blocks.count }
    /// Blocks that have been emitted as anchors.
    public var discoveredCount: Int { blocks.reduce(0) { $0 + ($1.id == nil ? 0 : 1) } }
    /// Triangle ids seen so far, over all blocks.
    public var seenTriangleCount: Int {
        var all = Set<Int32>()
        for block in blocks { all.formUnion(block.seen) }
        return all.count
    }

    /// Records the triangles a frame hit (`Raycaster.Frame.triangleIDs`, −1 ignored) and
    /// returns the anchor events that follow, in block order.
    public func observe(triangleIDs: [Int32]) -> [AnchorEvent] {
        var touched = Set<Int>()
        for id in triangleIDs where id >= 0 {
            for b in blockOfTriangle[Int(id)] where blocks[b].seen.insert(id).inserted {
                touched.insert(b)
            }
        }
        var events: [AnchorEvent] = []
        for b in touched.sorted() {
            let block = blocks[b]
            let seen = block.seen.count
            if block.id == nil {
                guard seen >= configuration.discoveryThreshold else { continue }
                let id = rng.nextUUID()
                blocks[b].id = id
                blocks[b].emittedCount = seen
                events.append(.added(payload(of: b)))
            } else if seen - block.emittedCount >= configuration.updateThreshold {
                blocks[b].emittedCount = seen
                if rng.chance(configuration.churnProbability) {
                    events.append(.removed(block.id!))
                    blocks[b].id = rng.nextUUID()
                    events.append(.added(payload(of: b)))
                } else {
                    events.append(.updated(payload(of: b)))
                }
            }
        }
        return events
    }

    /// Moves every discovered anchor by `translation` at once and returns their `.updated`
    /// events. Tracking's answer to recognising a place it has been before: the map shifts.
    public func applyLoopClosure(translation: SIMD3<Float>) -> [AnchorEvent] {
        var events: [AnchorEvent] = []
        for b in blocks.indices where blocks[b].id != nil {
            blocks[b].shift += translation
            events.append(.updated(payload(of: b)))
        }
        return events
    }

    /// Every discovered anchor, in block order, as of now.
    public func anchors() -> [MeshAnchorPayload] {
        blocks.indices.compactMap { blocks[$0].id == nil ? nil : payload(of: $0) }
    }

    /// The anchor for block `b`: its seen triangles, vertices deduplicated and made local to
    /// the block origin, faces reindexed, in ascending global order so the bytes are stable.
    private func payload(of b: Int) -> MeshAnchorPayload {
        let block = blocks[b]
        let seen = block.seen.sorted()
        var localIndex: [UInt32: UInt32] = [:]
        var vertices: [Float] = []
        var faces: [UInt32] = []
        var classes: [UInt8] = []
        vertices.reserveCapacity(seen.count * 9)
        faces.reserveCapacity(seen.count * 3)
        for t in seen {
            let tri = model.triangles[Int(t)]
            for g in [tri.x, tri.y, tri.z] {
                if let local = localIndex[g] {
                    faces.append(local)
                } else {
                    let local = UInt32(localIndex.count)
                    localIndex[g] = local
                    let p = model.vertices[Int(g)] - block.origin
                    vertices.append(contentsOf: [p.x, p.y, p.z])
                    faces.append(local)
                }
            }
            classes.append(model.classes[Int(t)].rawValue)
        }
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4(block.origin + block.shift, 1)
        return MeshAnchorPayload(id: block.id!, transform: transform, vertices: vertices, faces: faces, classes: classes)
    }
}
