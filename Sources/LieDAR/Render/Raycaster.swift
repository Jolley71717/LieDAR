import Foundation
import simd

/// Renders depth, confidence and a per-pixel triangle id for a camera looking into a
/// `RoomModel`, on the CPU, deterministically: plain scalar `Float` arithmetic in a fixed
/// order, a BVH built the same way every time, and a nearest-hit rule that does not depend on
/// traversal order (smallest `t`, ties to the lowest triangle id). Two renders of the same
/// inputs are bit-identical on every arm64 machine, which is what lets a golden test pin the
/// depth bytes exactly. No Metal, no GPU.
///
/// Depth is the distance along the camera's −Z axis (the plane distance the format specifies),
/// not the ray length: each pixel's ray is `(dx, dy, −1)` in camera space, so the hit
/// parameter `t` *is* the depth.
public final class Raycaster: Sendable {
    /// One rendered frame, tightly packed row-major, `width × height`.
    public struct Frame: Sendable, Equatable {
        public var width: Int
        public var height: Int
        /// Metres; 0 where no triangle was hit.
        public var depth: [Float32]
        /// 0 low, 1 medium, 2 high; 0 where nothing was hit.
        public var confidence: [UInt8]
        /// Index into `RoomModel.triangles`, or −1 for a miss.
        public var triangleIDs: [Int32]

        public var pixelCount: Int { width * height }
        public var hitCount: Int { triangleIDs.reduce(0) { $0 + ($1 >= 0 ? 1 : 0) } }

        /// Depth as a `FramePayload` plane.
        public func depthPlane() -> Plane<Float32> { Plane(values: depth, width: width, height: height) }
        public func confidencePlane() -> Plane<UInt8> { Plane(values: confidence, width: width, height: height) }

        /// Depth as the on-disk bytes (little-endian `Float32`, no padding).
        public func depthBytes() -> Data { depthPlane().tightlyPacked() }

        public func depthAt(x: Int, y: Int) -> Float32 { depth[y * width + x] }
        public func triangleAt(x: Int, y: Int) -> Int32 { triangleIDs[y * width + x] }
    }

    /// How confidence falls off with range and grazing angle. Real LiDAR confidence is a
    /// sensor-side estimate the API does not document; this is a plausible stand-in, no more.
    public struct ConfidenceModel: Sendable, Equatable {
        /// Hits closer than this with |cos θ| ≥ `highCosine` are high.
        public var highRange: Float = 3.0
        /// Hits closer than this with |cos θ| ≥ `mediumCosine` are medium; anything else is low.
        public var mediumRange: Float = 5.0
        public var highCosine: Float = 0.5
        public var mediumCosine: Float = 0.2

        public init(highRange: Float = 3.0, mediumRange: Float = 5.0, highCosine: Float = 0.5, mediumCosine: Float = 0.2) {
            self.highRange = highRange
            self.mediumRange = mediumRange
            self.highCosine = highCosine
            self.mediumCosine = mediumCosine
        }
    }

    public let model: RoomModel
    public let confidenceModel: ConfidenceModel

    // Per-triangle: v0, e1 = v1 − v0, e2 = v2 − v0, unit normal — 12 floats, in model order.
    private let triangleData: [Float]
    // Flat BVH. Node i: bounds[6i..<6i+6]; `first[i]` is the first index into `order` for a
    // leaf (count[i] > 0) or the right child for an interior node (count[i] == 0, left = i + 1).
    private let nodeBounds: [Float]
    private let nodeFirst: [Int32]
    private let nodeCount: [Int32]
    private let order: [Int32]
    private static let leafSize = 4

    public init(model: RoomModel, confidenceModel: ConfidenceModel = ConfidenceModel()) {
        self.model = model
        self.confidenceModel = confidenceModel

        var data = [Float]()
        data.reserveCapacity(model.triangleCount * 12)
        var centroids = [SIMD3<Float>]()
        var boundsMin = [SIMD3<Float>](), boundsMax = [SIMD3<Float>]()
        for id in 0..<model.triangleCount {
            let (a, b, c) = model.corners(of: id)
            let e1 = b - a, e2 = c - a
            var n = SIMD3<Float>(e1.y * e2.z - e1.z * e2.y, e1.z * e2.x - e1.x * e2.z, e1.x * e2.y - e1.y * e2.x)
            let len = (n.x * n.x + n.y * n.y + n.z * n.z).squareRoot()
            if len > 0 { n /= len }
            data.append(contentsOf: [a.x, a.y, a.z, e1.x, e1.y, e1.z, e2.x, e2.y, e2.z, n.x, n.y, n.z])
            centroids.append((a + b + c) / 3)
            boundsMin.append(simd_min(simd_min(a, b), c))
            boundsMax.append(simd_max(simd_max(a, b), c))
        }
        triangleData = data

        var order = Array(0..<Int32(model.triangleCount))
        var bounds = [Float](), first = [Int32](), count = [Int32]()
        Self.build(range: 0..<order.count, order: &order, centroids: centroids, boundsMin: boundsMin, boundsMax: boundsMax,
                   nodeBounds: &bounds, nodeFirst: &first, nodeCount: &count)
        self.order = order
        nodeBounds = bounds
        nodeFirst = first
        nodeCount = count
    }

    public var nodeCountForTesting: Int { nodeCount.count }

    /// Median split on the longest axis of the centroid bounds; leaves hold ≤ `leafSize`.
    private static func build(range: Range<Int>, order: inout [Int32], centroids: [SIMD3<Float>],
                              boundsMin: [SIMD3<Float>], boundsMax: [SIMD3<Float>],
                              nodeBounds: inout [Float], nodeFirst: inout [Int32], nodeCount: inout [Int32]) {
        let index = nodeCount.count
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        var clo = lo, chi = hi
        for i in range {
            let t = Int(order[i])
            lo = simd_min(lo, boundsMin[t]); hi = simd_max(hi, boundsMax[t])
            clo = simd_min(clo, centroids[t]); chi = simd_max(chi, centroids[t])
        }
        if range.isEmpty { lo = .zero; hi = .zero }
        nodeBounds.append(contentsOf: [lo.x, lo.y, lo.z, hi.x, hi.y, hi.z])
        nodeFirst.append(Int32(range.lowerBound))
        nodeCount.append(Int32(range.count))
        guard range.count > leafSize else { return }

        let extent = chi - clo
        let axis = extent.x >= extent.y && extent.x >= extent.z ? 0 : (extent.y >= extent.z ? 1 : 2)
        // Stable sort by centroid, then by id, so the split is a pure function of the input.
        let slice = order[range].sorted { a, b in
            let ca = centroids[Int(a)][axis], cb = centroids[Int(b)][axis]
            return ca != cb ? ca < cb : a < b
        }
        order.replaceSubrange(range, with: slice)
        let mid = range.lowerBound + range.count / 2
        nodeCount[index] = 0
        build(range: range.lowerBound..<mid, order: &order, centroids: centroids, boundsMin: boundsMin, boundsMax: boundsMax,
              nodeBounds: &nodeBounds, nodeFirst: &nodeFirst, nodeCount: &nodeCount)
        nodeFirst[index] = Int32(nodeCount.count)
        build(range: mid..<range.upperBound, order: &order, centroids: centroids, boundsMin: boundsMin, boundsMax: boundsMax,
              nodeBounds: &nodeBounds, nodeFirst: &nodeFirst, nodeCount: &nodeCount)
    }

    // MARK: Render

    /// Renders `resolution` pixels for a camera at `cameraToWorld` (camera looks down its −Z,
    /// +X right, +Y up) whose `intrinsics` are given for their own `imageResolution` and are
    /// rescaled to `resolution` here. Rays pass through pixel centres (`u + 0.5`, `v + 0.5`).
    public func render(cameraToWorld: simd_float4x4, intrinsics: CameraIntrinsics,
                       resolution: PixelSize = CameraIntrinsics.depthResolution) -> Frame {
        let width = resolution.width, height = resolution.height
        let k = intrinsics.scaled(to: resolution)
        let pixels = width * height
        var depth = [Float32](repeating: 0, count: pixels)
        var confidence = [UInt8](repeating: 0, count: pixels)
        var ids = [Int32](repeating: -1, count: pixels)

        let c0 = cameraToWorld.columns.0, c1 = cameraToWorld.columns.1, c2 = cameraToWorld.columns.2
        let ox = cameraToWorld.columns.3.x, oy = cameraToWorld.columns.3.y, oz = cameraToWorld.columns.3.z
        let cm = confidenceModel
        let triCount = model.triangleCount

        triangleData.withUnsafeBufferPointer { tri in
            nodeBounds.withUnsafeBufferPointer { nb in
                nodeFirst.withUnsafeBufferPointer { nf in
                    nodeCount.withUnsafeBufferPointer { nc in
                        order.withUnsafeBufferPointer { ord in
                            depth.withUnsafeMutableBufferPointer { depthOut in
                                confidence.withUnsafeMutableBufferPointer { confOut in
                                    ids.withUnsafeMutableBufferPointer { idOut in
                                        var stack = [Int32](repeating: 0, count: 64)
                                        stack.withUnsafeMutableBufferPointer { stack in
                                            for v in 0..<height {
                                                let dy = -((Float(v) + 0.5) - k.cy) / k.fy
                                                for u in 0..<width {
                                                    let dx = ((Float(u) + 0.5) - k.cx) / k.fx
                                                    // World direction = R · (dx, dy, −1).
                                                    let wx = c0.x * dx + c1.x * dy - c2.x
                                                    let wy = c0.y * dx + c1.y * dy - c2.y
                                                    let wz = c0.z * dx + c1.z * dy - c2.z
                                                    var bestT = Float.greatestFiniteMagnitude
                                                    var bestID: Int32 = -1
                                                    if triCount > 0 {
                                                        Self.trace(ox, oy, oz, wx, wy, wz, tri: tri, nb: nb, nf: nf, nc: nc, ord: ord,
                                                                   stack: stack, bestT: &bestT, bestID: &bestID)
                                                    }
                                                    let p = v * width + u
                                                    guard bestID >= 0 else { continue }
                                                    depthOut[p] = bestT
                                                    idOut[p] = bestID
                                                    // |cos θ| between the unit ray and the triangle normal.
                                                    let base = Int(bestID) * 12
                                                    let len = (wx * wx + wy * wy + wz * wz).squareRoot()
                                                    let cosine = abs(wx * tri[base + 9] + wy * tri[base + 10] + wz * tri[base + 11]) / len
                                                    if bestT <= cm.highRange && cosine >= cm.highCosine {
                                                        confOut[p] = 2
                                                    } else if bestT <= cm.mediumRange && cosine >= cm.mediumCosine {
                                                        confOut[p] = 1
                                                    } else {
                                                        confOut[p] = 0
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return Frame(width: width, height: height, depth: depth, confidence: confidence, triangleIDs: ids)
    }

    /// Nearest hit along the ray from `(ox, oy, oz)` in direction `(dx, dy, dz)`; `bestT` is
    /// the parameter (depth), `bestID` the triangle, or −1.
    @inline(__always)
    private static func trace(_ ox: Float, _ oy: Float, _ oz: Float, _ dx: Float, _ dy: Float, _ dz: Float,
                              tri: UnsafeBufferPointer<Float>, nb: UnsafeBufferPointer<Float>,
                              nf: UnsafeBufferPointer<Int32>, nc: UnsafeBufferPointer<Int32>, ord: UnsafeBufferPointer<Int32>,
                              stack: UnsafeMutableBufferPointer<Int32>, bestT: inout Float, bestID: inout Int32) {
        let invX = 1 / dx, invY = 1 / dy, invZ = 1 / dz
        var sp = 0
        stack[0] = 0
        sp = 1
        while sp > 0 {
            sp -= 1
            let node = Int(stack[sp])
            let b = node * 6
            // Slab test. `Float.minimum/maximum` ignore a NaN operand, which is what a ray lying
            // exactly in a slab plane (0 × ∞) must produce: no constraint on that axis.
            var t0 = (nb[b] - ox) * invX, t1 = (nb[b + 3] - ox) * invX
            var tmin = Float.minimum(t0, t1), tmax = Float.maximum(t0, t1)
            t0 = (nb[b + 1] - oy) * invY; t1 = (nb[b + 4] - oy) * invY
            tmin = Float.maximum(tmin, Float.minimum(t0, t1)); tmax = Float.minimum(tmax, Float.maximum(t0, t1))
            t0 = (nb[b + 2] - oz) * invZ; t1 = (nb[b + 5] - oz) * invZ
            tmin = Float.maximum(tmin, Float.minimum(t0, t1)); tmax = Float.minimum(tmax, Float.maximum(t0, t1))
            if tmax < max(tmin, 0) || tmin > bestT { continue }

            let count = Int(nc[node])
            if count == 0 {
                // Interior: push right then left so left is visited first (order only affects speed).
                stack[sp] = nf[node]; sp += 1
                stack[sp] = Int32(node + 1); sp += 1
                continue
            }
            let first = Int(nf[node])
            for i in first..<(first + count) {
                let id = ord[i]
                let base = Int(id) * 12
                // Möller–Trumbore, scalar.
                let e1x = tri[base + 3], e1y = tri[base + 4], e1z = tri[base + 5]
                let e2x = tri[base + 6], e2y = tri[base + 7], e2z = tri[base + 8]
                let px = dy * e2z - dz * e2y, py = dz * e2x - dx * e2z, pz = dx * e2y - dy * e2x
                let det = e1x * px + e1y * py + e1z * pz
                if abs(det) < 1e-12 { continue }
                let invDet = 1 / det
                let sx = ox - tri[base], sy = oy - tri[base + 1], sz = oz - tri[base + 2]
                let uu = (sx * px + sy * py + sz * pz) * invDet
                if uu < 0 || uu > 1 { continue }
                let qx = sy * e1z - sz * e1y, qy = sz * e1x - sx * e1z, qz = sx * e1y - sy * e1x
                let vv = (dx * qx + dy * qy + dz * qz) * invDet
                if vv < 0 || uu + vv > 1 { continue }
                let t = (e2x * qx + e2y * qy + e2z * qz) * invDet
                if t <= 1e-4 { continue }
                if t < bestT || (t == bestT && id < bestID) {
                    bestT = t
                    bestID = id
                }
            }
        }
    }
}
