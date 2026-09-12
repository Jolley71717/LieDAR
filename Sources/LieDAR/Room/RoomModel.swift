import Foundation
import simd

/// A triangle mesh with one `MeshClassification` per triangle, in world metres. Built from a
/// `RoomSpec` or loaded from an ASCII OBJ; consumed by `Raycaster` (depth) and `AnchorChunker`
/// (anchors). Triangle `i` is `triangles[i]`, three indices into `vertices`, and `classes[i]`.
public struct RoomModel: Sendable, Equatable {
    public var vertices: [SIMD3<Float>]
    public var triangles: [SIMD3<UInt32>]
    public var classes: [MeshClassification]

    public init(vertices: [SIMD3<Float>], triangles: [SIMD3<UInt32>], classes: [MeshClassification]) {
        precondition(triangles.count == classes.count, "one class per triangle")
        self.vertices = vertices
        self.triangles = triangles
        self.classes = classes
    }

    public var triangleCount: Int { triangles.count }

    /// Axis-aligned bounds of every vertex; zero box when empty.
    public var bounds: (min: SIMD3<Float>, max: SIMD3<Float>) {
        guard var lo = vertices.first else { return (.zero, .zero) }
        var hi = lo
        for v in vertices {
            lo = simd_min(lo, v)
            hi = simd_max(hi, v)
        }
        return (lo, hi)
    }

    /// Corner positions of triangle `id`.
    public func corners(of id: Int) -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) {
        let t = triangles[id]
        return (vertices[Int(t.x)], vertices[Int(t.y)], vertices[Int(t.z)])
    }

    /// Triangles per class.
    public func classHistogram() -> [MeshClassification: Int] {
        var histogram: [MeshClassification: Int] = [:]
        for c in classes { histogram[c, default: 0] += 1 }
        return histogram
    }

    // MARK: Parametric

    /// A wall of the footprint outline: start and end on the floor plane, in xz.
    public struct WallSegment: Sendable, Equatable {
        public var start: SIMD2<Float>
        public var end: SIMD2<Float>
        public var length: Float { simd_length(end - start) }
    }

    /// The outline walls of `spec`, numbered as `RoomSpec` documents.
    public static func wallSegments(of spec: RoomSpec) -> [WallSegment] {
        let w = spec.width, d = spec.depth
        var corners: [SIMD2<Float>]
        if let cut = spec.lCut {
            corners = [SIMD2(0, 0), SIMD2(w, 0), SIMD2(w, d - cut.cutDepth), SIMD2(w - cut.cutWidth, d - cut.cutDepth),
                       SIMD2(w - cut.cutWidth, d), SIMD2(0, d)]
        } else {
            corners = [SIMD2(0, 0), SIMD2(w, 0), SIMD2(w, d), SIMD2(0, d)]
        }
        return corners.indices.map { WallSegment(start: corners[$0], end: corners[($0 + 1) % corners.count]) }
    }

    public static func random(seed: UInt64) -> RoomModel {
        parametric(RoomSpec.random(seed: seed))
    }

    /// Meshes `spec`: walls with their openings filled by door/window surfaces, floor and
    /// ceiling (two rectangles for an L-shape), the bulkhead's underside and sides, and each
    /// furniture box's top and sides. Faces are split into cells no larger than
    /// `spec.tessellation`; shared vertices are merged so the surfaces are stitched.
    public static func parametric(_ spec: RoomSpec) -> RoomModel {
        var builder = MeshBuilder(cell: spec.tessellation)
        let h = spec.ceilingHeight
        let walls = wallSegments(of: spec)

        // Walls, each with its openings cut out and filled.
        for (index, wall) in walls.enumerated() {
            let direction = simd_normalize(wall.end - wall.start)
            let length = wall.length
            let inward = interiorNormal(of: wall, spec: spec)
            let inward3 = SIMD3<Float>(inward.x, 0, inward.y)
            func point(_ s: Float, _ y: Float) -> SIMD3<Float> {
                let p = wall.start + direction * s
                return SIMD3(p.x, y, p.y)
            }
            func piece(_ s0: Float, _ s1: Float, _ y0: Float, _ y1: Float, _ cls: MeshClassification) {
                guard s1 - s0 > 1e-4, y1 - y0 > 1e-4 else { return }
                builder.addQuad(point(s0, y0), point(s1, y0), point(s1, y1), point(s0, y1), normal: inward3, cls)
            }
            let openings = spec.openings.filter { $0.wall == index }
                .map { opening -> RoomSpec.WallOpening in
                    var o = opening
                    o.offset = max(0, min(length, o.offset))
                    o.width = max(0, min(length - o.offset, o.width))
                    o.sill = max(0, min(h, o.sill))
                    o.head = max(o.sill, min(h, o.head))
                    return o
                }
                .sorted { $0.offset < $1.offset }
            var cursor: Float = 0
            for opening in openings {
                let s0 = max(cursor, opening.offset), s1 = opening.offset + opening.width
                guard s1 > s0 else { continue }
                piece(cursor, s0, 0, h, .wall)
                piece(s0, s1, 0, opening.sill, .wall)
                piece(s0, s1, opening.sill, opening.head, opening.classification)
                piece(s0, s1, opening.head, h, .wall)
                cursor = s1
            }
            piece(cursor, length, 0, h, .wall)
        }

        // Floor and ceiling as one or two rectangles.
        var rects: [(SIMD2<Float>, SIMD2<Float>)] = []
        if let cut = spec.lCut {
            rects.append((SIMD2(0, 0), SIMD2(spec.width - cut.cutWidth, spec.depth)))
            rects.append((SIMD2(spec.width - cut.cutWidth, 0), SIMD2(spec.width, spec.depth - cut.cutDepth)))
        } else {
            rects.append((SIMD2(0, 0), SIMD2(spec.width, spec.depth)))
        }
        for (lo, hi) in rects {
            builder.addQuad(SIMD3(lo.x, 0, lo.y), SIMD3(hi.x, 0, lo.y), SIMD3(hi.x, 0, hi.y), SIMD3(lo.x, 0, hi.y),
                            normal: SIMD3(0, 1, 0), .floor)
            builder.addQuad(SIMD3(lo.x, h, lo.y), SIMD3(hi.x, h, lo.y), SIMD3(hi.x, h, hi.y), SIMD3(lo.x, h, hi.y),
                            normal: SIMD3(0, -1, 0), .ceiling)
        }

        // Bulkhead: underside (ceiling) and two sides (wall), spanning the footprint at its position.
        if let b = spec.bulkhead, b.drop > 0, b.width > 0 {
            let y0 = h - b.drop
            switch b.axis {
            case .x:
                let z0 = b.offset, z1 = b.offset + b.width
                var x1 = spec.width
                if let cut = spec.lCut, z1 > spec.depth - cut.cutDepth { x1 = spec.width - cut.cutWidth }
                builder.addQuad(SIMD3(0, y0, z0), SIMD3(x1, y0, z0), SIMD3(x1, y0, z1), SIMD3(0, y0, z1), normal: SIMD3(0, -1, 0), .ceiling)
                builder.addQuad(SIMD3(0, y0, z0), SIMD3(x1, y0, z0), SIMD3(x1, h, z0), SIMD3(0, h, z0), normal: SIMD3(0, 0, -1), .wall)
                builder.addQuad(SIMD3(0, y0, z1), SIMD3(x1, y0, z1), SIMD3(x1, h, z1), SIMD3(0, h, z1), normal: SIMD3(0, 0, 1), .wall)
            case .z:
                let x0 = b.offset, x1 = b.offset + b.width
                var z1 = spec.depth
                if let cut = spec.lCut, x1 > spec.width - cut.cutWidth { z1 = spec.depth - cut.cutDepth }
                builder.addQuad(SIMD3(x0, y0, 0), SIMD3(x1, y0, 0), SIMD3(x1, y0, z1), SIMD3(x0, y0, z1), normal: SIMD3(0, -1, 0), .ceiling)
                builder.addQuad(SIMD3(x0, y0, 0), SIMD3(x0, y0, z1), SIMD3(x0, h, z1), SIMD3(x0, h, 0), normal: SIMD3(-1, 0, 0), .wall)
                builder.addQuad(SIMD3(x1, y0, 0), SIMD3(x1, y0, z1), SIMD3(x1, h, z1), SIMD3(x1, h, 0), normal: SIMD3(1, 0, 0), .wall)
            }
        }

        // Furniture: top and four sides.
        for box in spec.furniture {
            let lo = box.min, hi = box.max
            guard hi.x > lo.x, hi.y > lo.y, hi.z > lo.z else { continue }
            let c = box.classification
            builder.addQuad(SIMD3(lo.x, hi.y, lo.z), SIMD3(hi.x, hi.y, lo.z), SIMD3(hi.x, hi.y, hi.z), SIMD3(lo.x, hi.y, hi.z), normal: SIMD3(0, 1, 0), c)
            builder.addQuad(SIMD3(lo.x, lo.y, lo.z), SIMD3(hi.x, lo.y, lo.z), SIMD3(hi.x, hi.y, lo.z), SIMD3(lo.x, hi.y, lo.z), normal: SIMD3(0, 0, -1), c)
            builder.addQuad(SIMD3(lo.x, lo.y, hi.z), SIMD3(hi.x, lo.y, hi.z), SIMD3(hi.x, hi.y, hi.z), SIMD3(lo.x, hi.y, hi.z), normal: SIMD3(0, 0, 1), c)
            builder.addQuad(SIMD3(lo.x, lo.y, lo.z), SIMD3(lo.x, lo.y, hi.z), SIMD3(lo.x, hi.y, hi.z), SIMD3(lo.x, hi.y, lo.z), normal: SIMD3(-1, 0, 0), c)
            builder.addQuad(SIMD3(hi.x, lo.y, lo.z), SIMD3(hi.x, lo.y, hi.z), SIMD3(hi.x, hi.y, hi.z), SIMD3(hi.x, hi.y, lo.z), normal: SIMD3(1, 0, 0), c)
        }

        return builder.model()
    }

    /// The unit normal of a wall pointing into the room.
    private static func interiorNormal(of wall: WallSegment, spec: RoomSpec) -> SIMD2<Float> {
        let d = simd_normalize(wall.end - wall.start)
        let n = SIMD2<Float>(-d.y, d.x)
        let mid = (wall.start + wall.end) * 0.5
        let probe = mid + n * 0.01
        return spec.contains(x: probe.x, z: probe.y) ? n : -n
    }
}

/// Accumulates quads split into a grid, merging vertices at identical (quantized) positions so
/// adjacent faces share edges. Deterministic: vertex ids are assigned in insertion order.
struct MeshBuilder {
    let cell: Float
    private(set) var vertices: [SIMD3<Float>] = []
    private(set) var triangles: [SIMD3<UInt32>] = []
    private(set) var classes: [MeshClassification] = []
    private var lookup: [SIMD3<Int32>: UInt32] = [:]

    init(cell: Float) {
        self.cell = cell
    }

    mutating func vertex(_ p: SIMD3<Float>) -> UInt32 {
        let key = SIMD3<Int32>(Int32((p.x * 10_000).rounded()), Int32((p.y * 10_000).rounded()), Int32((p.z * 10_000).rounded()))
        if let id = lookup[key] { return id }
        let id = UInt32(vertices.count)
        vertices.append(p)
        lookup[key] = id
        return id
    }

    /// Adds the quad `a b c d` (a planar parallelogram: `d = a + (c - b)`), subdivided so no
    /// cell edge exceeds `cell`, wound so each triangle's normal points along `normal`.
    mutating func addQuad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>,
                          normal: SIMD3<Float>, _ cls: MeshClassification) {
        let u = b - a, v = d - a
        assert(simd_length(c - (a + u + v)) < 1e-3, "quad is not a parallelogram")
        let nu = max(1, Int((simd_length(u) / cell - 1e-4).rounded(.up)))
        let nv = max(1, Int((simd_length(v) / cell - 1e-4).rounded(.up)))
        let flip = simd_dot(simd_cross(u, v), normal) < 0
        var grid: [UInt32] = []
        grid.reserveCapacity((nu + 1) * (nv + 1))
        for j in 0...nv {
            for i in 0...nu {
                let p = a + u * (Float(i) / Float(nu)) + v * (Float(j) / Float(nv))
                grid.append(vertex(p))
            }
        }
        for j in 0..<nv {
            for i in 0..<nu {
                let p00 = grid[j * (nu + 1) + i], p10 = grid[j * (nu + 1) + i + 1]
                let p01 = grid[(j + 1) * (nu + 1) + i], p11 = grid[(j + 1) * (nu + 1) + i + 1]
                if flip {
                    triangles.append(SIMD3(p00, p11, p10))
                    triangles.append(SIMD3(p00, p01, p11))
                } else {
                    triangles.append(SIMD3(p00, p10, p11))
                    triangles.append(SIMD3(p00, p11, p01))
                }
                classes.append(cls)
                classes.append(cls)
            }
        }
    }

    func model() -> RoomModel {
        RoomModel(vertices: vertices, triangles: triangles, classes: classes)
    }
}
