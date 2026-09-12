import Foundation
import simd

/// A parametric room, in metres. The floor is `y = 0`, the footprint is `x ∈ [0, width]`,
/// `z ∈ [0, depth]` with an optional rectangular notch removed from the `(+x, +z)` corner
/// (the L-shape), and the ceiling is at `y = ceilingHeight`. The world frame is ARKit's
/// (right-handed, +Y up); a virtual camera starts somewhere inside.
///
/// Walls are the edges of the footprint outline, numbered from the south wall (`z = 0`, running
/// +x) counter-clockwise seen from above: for a rectangle 0 south, 1 east, 2 north, 3 west; for
/// an L-shape 0 south, 1 east (short), 2 the notch's inner north face, 3 the notch's inner west
/// face, 4 north, 5 west. `RoomModel.wallSegments(of:)` lists them with their lengths.
public struct RoomSpec: Sendable, Equatable {
    /// The notch removed from the `(+x, +z)` corner.
    public struct LCut: Sendable, Equatable {
        /// Extent of the notch along x, from `width - cutWidth` to `width`.
        public var cutWidth: Float
        /// Extent of the notch along z, from `depth - cutDepth` to `depth`.
        public var cutDepth: Float

        public init(cutWidth: Float, cutDepth: Float) {
            self.cutWidth = cutWidth
            self.cutDepth = cutDepth
        }
    }

    /// A door or window in a wall. Its surface is meshed and classified, as a closed door or a
    /// pane, so the room stays closed and every ray hits something.
    public struct WallOpening: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case door
            case window
        }

        public var kind: Kind
        /// Wall index; see `RoomSpec`.
        public var wall: Int
        /// Distance along the wall from its start to the opening's near edge.
        public var offset: Float
        public var width: Float
        /// Height of the bottom edge above the floor (0 for a door).
        public var sill: Float
        /// Height of the top edge above the floor.
        public var head: Float

        public init(kind: Kind, wall: Int, offset: Float, width: Float, sill: Float, head: Float) {
            self.kind = kind
            self.wall = wall
            self.offset = offset
            self.width = width
            self.sill = sill
            self.head = head
        }

        public static func door(wall: Int, offset: Float, width: Float = 0.9, head: Float = 2.05) -> WallOpening {
            WallOpening(kind: .door, wall: wall, offset: offset, width: width, sill: 0, head: head)
        }

        public static func window(wall: Int, offset: Float, width: Float = 1.2, sill: Float = 1.2, head: Float = 2.0) -> WallOpening {
            WallOpening(kind: .window, wall: wall, offset: offset, width: width, sill: sill, head: head)
        }

        var classification: MeshClassification {
            switch kind {
            case .door: return .door
            case .window: return .window
            }
        }
    }

    /// A box hanging under the ceiling across the whole room along one axis, a duct or beam
    /// enclosure. Its underside is classified `ceiling`, its sides `wall`.
    public struct Bulkhead: Sendable, Equatable {
        public enum Axis: Sendable, Equatable {
            /// Runs along x; `offset` and `width` are measured along z.
            case x
            /// Runs along z; `offset` and `width` are measured along x.
            case z
        }

        public var axis: Axis
        public var offset: Float
        public var width: Float
        /// How far below the ceiling its underside hangs.
        public var drop: Float

        public init(axis: Axis, offset: Float, width: Float, drop: Float) {
            self.axis = axis
            self.offset = offset
            self.width = width
            self.drop = drop
        }
    }

    /// An axis-aligned box standing on the floor, classified `table` or `seat`. Five faces
    /// (no underside).
    public struct FurnitureBox: Sendable, Equatable {
        public var min: SIMD3<Float>
        public var max: SIMD3<Float>
        public var classification: MeshClassification

        public init(min: SIMD3<Float>, max: SIMD3<Float>, classification: MeshClassification) {
            self.min = min
            self.max = max
            self.classification = classification
        }

        public static func table(x: Float, z: Float, width: Float = 1.2, depth: Float = 0.7, height: Float = 0.75) -> FurnitureBox {
            FurnitureBox(min: SIMD3(x, 0, z), max: SIMD3(x + width, height, z + depth), classification: .table)
        }

        public static func seat(x: Float, z: Float, size: Float = 0.5, height: Float = 0.45) -> FurnitureBox {
            FurnitureBox(min: SIMD3(x, 0, z), max: SIMD3(x + size, height, z + size), classification: .seat)
        }
    }

    public var width: Float
    public var depth: Float
    public var ceilingHeight: Float
    public var lCut: LCut?
    public var openings: [WallOpening]
    public var bulkhead: Bulkhead?
    public var furniture: [FurnitureBox]
    /// Largest edge of any mesh cell; big faces are split into a grid this fine so anchor
    /// chunking has something to chunk (a real reconstruction's triangles are ~5 cm).
    public var tessellation: Float

    public init(width: Float, depth: Float, ceilingHeight: Float, lCut: LCut? = nil,
                openings: [WallOpening] = [], bulkhead: Bulkhead? = nil, furniture: [FurnitureBox] = [],
                tessellation: Float = 0.5) {
        precondition(width > 0 && depth > 0 && ceilingHeight > 0, "room dimensions must be positive")
        precondition(tessellation > 0, "tessellation must be positive")
        self.width = width
        self.depth = depth
        self.ceilingHeight = ceilingHeight
        self.lCut = lCut
        self.openings = openings
        self.bulkhead = bulkhead
        self.furniture = furniture
        self.tessellation = tessellation
    }

    /// The canonical test room: 5 × 4 × 2.4 m, one door in the south wall, one window in the
    /// north wall, a bulkhead along x, one table. Every golden test uses this.
    public static let canonical = RoomSpec(
        width: 5, depth: 4, ceilingHeight: 2.4,
        openings: [.door(wall: 0, offset: 0.8), .window(wall: 2, offset: 1.5)],
        bulkhead: Bulkhead(axis: .x, offset: 1.0, width: 0.6, drop: 0.35),
        furniture: [.table(x: 2.8, z: 2.6)])

    /// A seed-deterministic room: size, L-shape, one door, up to two windows, a bulkhead and
    /// up to three pieces of furniture are all drawn from `SeededRandom(seed:)`.
    public static func random(seed: UInt64) -> RoomSpec {
        var rng = SeededRandom(seed: seed, label: 0x726F_6F6D) // "room"
        let width = rng.nextFloat(in: 3.5...7.0).rounded(toPlaces: 2)
        let depth = rng.nextFloat(in: 3.0...6.0).rounded(toPlaces: 2)
        let height = rng.nextFloat(in: 2.1...2.6).rounded(toPlaces: 2)

        var lCut: LCut?
        if rng.chance(0.4) {
            lCut = LCut(cutWidth: (width * rng.nextFloat(in: 0.25...0.45)).rounded(toPlaces: 2),
                        cutDepth: (depth * rng.nextFloat(in: 0.25...0.45)).rounded(toPlaces: 2))
        }
        var spec = RoomSpec(width: width, depth: depth, ceilingHeight: height, lCut: lCut)
        let walls = RoomModel.wallSegments(of: spec)

        // One door in a wall long enough for it, then 0–2 windows in other walls.
        var openings: [WallOpening] = []
        var candidates = walls.indices.filter { walls[$0].length >= 1.6 }
        if !candidates.isEmpty {
            let wall = candidates.remove(at: rng.nextInt(below: candidates.count))
            let offset = rng.nextFloat(in: 0.3...(walls[wall].length - 1.2)).rounded(toPlaces: 2)
            openings.append(.door(wall: wall, offset: offset, head: min(2.05, height - 0.1)))
        }
        let windows = rng.nextInt(below: 3)
        for _ in 0..<windows where !candidates.isEmpty {
            let wall = candidates.remove(at: rng.nextInt(below: candidates.count))
            let offset = rng.nextFloat(in: 0.3...(walls[wall].length - 1.5)).rounded(toPlaces: 2)
            let sill = min(1.2, height - 1.0)
            openings.append(.window(wall: wall, offset: offset, sill: sill, head: min(sill + 0.8, height - 0.15)))
        }
        spec.openings = openings

        if rng.chance(0.5) {
            let along: Bulkhead.Axis = rng.chance(0.5) ? .x : .z
            let across = along == .x ? depth : width
            spec.bulkhead = Bulkhead(axis: along,
                                     offset: rng.nextFloat(in: 0.5...(across - 1.1)).rounded(toPlaces: 2),
                                     width: rng.nextFloat(in: 0.4...0.8).rounded(toPlaces: 2),
                                     drop: rng.nextFloat(in: 0.25...0.45).rounded(toPlaces: 2))
        }

        // Furniture stays inside the full-depth part of the footprint and off the walls.
        let usableWidth = width - (lCut?.cutWidth ?? 0)
        let pieces = rng.nextInt(below: 4)
        var furniture: [FurnitureBox] = []
        for _ in 0..<pieces {
            let isTable = rng.chance(0.6)
            let size = isTable ? SIMD2<Float>(1.2, 0.7) : SIMD2<Float>(0.5, 0.5)
            guard usableWidth - size.x > 1.2, depth - size.y > 1.2 else { continue }
            let x = rng.nextFloat(in: 0.6...(usableWidth - size.x - 0.6)).rounded(toPlaces: 2)
            let z = rng.nextFloat(in: 0.6...(depth - size.y - 0.6)).rounded(toPlaces: 2)
            furniture.append(isTable ? .table(x: x, z: z) : .seat(x: x, z: z))
        }
        spec.furniture = furniture
        return spec
    }

    /// The footprint's bounding box on the floor.
    public var footprintMin: SIMD2<Float> { SIMD2(0, 0) }
    public var footprintMax: SIMD2<Float> { SIMD2(width, depth) }

    /// Whether a floor point lies inside the footprint (outside the notch).
    public func contains(x: Float, z: Float) -> Bool {
        guard x >= 0, x <= width, z >= 0, z <= depth else { return false }
        if let lCut, x > width - lCut.cutWidth, z > depth - lCut.cutDepth { return false }
        return true
    }
}

extension Float {
    func rounded(toPlaces places: Int) -> Float {
        let scale = Float(pow(10.0, Double(places)))
        return (self * scale).rounded() / scale
    }
}
