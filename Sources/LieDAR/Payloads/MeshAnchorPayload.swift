import Foundation
import simd

/// One mesh anchor, copied out of its source: anchor-local geometry plus the anchor-to-world
/// transform. Exactly what `mesh/<id>.vertices|faces|classes` hold, so the recorder writes
/// the three `Data` values verbatim.
public struct MeshAnchorPayload: Sendable, Equatable {
    public enum LayoutError: Error, Equatable, Sendable {
        case vertices(expectedBytes: Int, got: Int)
        case faces(expectedBytes: Int, got: Int)
        case classes(expectedBytes: Int, got: Int)
    }

    /// The anchor's identity; also the base name of its three files.
    public var id: UUID
    /// Anchor-to-world. `world = transform × [x y z 1]`.
    public var transform: simd_float4x4
    /// `vertexCount × 3` little-endian `Float32`, xyz interleaved, anchor-local metres.
    public var vertices: Data
    /// `faceCount × 3` little-endian `UInt32` indices into `vertices`.
    public var faces: Data
    /// `faceCount` bytes, one class per face: 0 none, 1 wall, 2 floor, 3 ceiling, 4 table,
    /// 5 seat, 6 window, 7 door.
    public var classes: Data
    public var vertexCount: Int
    public var faceCount: Int

    public static let bytesPerVertex = 3 * MemoryLayout<Float32>.size
    public static let bytesPerFace = 3 * MemoryLayout<UInt32>.size

    /// Wraps existing bytes without checking them; call `validate()` before trusting the counts.
    public init(id: UUID, transform: simd_float4x4, vertices: Data, faces: Data, classes: Data,
                vertexCount: Int, faceCount: Int) {
        self.id = id
        self.transform = transform
        self.vertices = vertices
        self.faces = faces
        self.classes = classes
        self.vertexCount = vertexCount
        self.faceCount = faceCount
    }

    /// Builds the byte buffers from typed arrays. `vertices` is xyz interleaved
    /// (`count % 3 == 0`); `faces` is three indices per triangle; `classes` is one per face
    /// (padded with 0 = none, or truncated, to `faces.count / 3`).
    public init(id: UUID, transform: simd_float4x4, vertices: [Float], faces: [UInt32], classes: [UInt8]) {
        precondition(vertices.count % 3 == 0, "vertices are xyz triples")
        precondition(faces.count % 3 == 0, "faces are index triples")
        let faceCount = faces.count / 3
        var perFace = Array(classes.prefix(faceCount))
        if perFace.count < faceCount { perFace.append(contentsOf: repeatElement(0, count: faceCount - perFace.count)) }
        self.init(id: id, transform: transform,
                  vertices: vertices.withUnsafeBufferPointer { Data(buffer: $0) },
                  faces: faces.withUnsafeBufferPointer { Data(buffer: $0) },
                  classes: Data(perFace),
                  vertexCount: vertices.count / 3, faceCount: faceCount)
    }

    /// Throws when a buffer's length disagrees with its count.
    public func validate() throws {
        guard vertices.count == vertexCount * Self.bytesPerVertex else {
            throw LayoutError.vertices(expectedBytes: vertexCount * Self.bytesPerVertex, got: vertices.count)
        }
        guard faces.count == faceCount * Self.bytesPerFace else {
            throw LayoutError.faces(expectedBytes: faceCount * Self.bytesPerFace, got: faces.count)
        }
        guard classes.count == faceCount else {
            throw LayoutError.classes(expectedBytes: faceCount, got: classes.count)
        }
    }

    /// Anchor-local vertex positions.
    public func vertexArray() -> [SIMD3<Float>] {
        let floats: [Float] = vertices.withUnsafeBytes { Array($0.bindMemory(to: Float.self).prefix(vertexCount * 3)) }
        return (0..<vertexCount).map { SIMD3(floats[$0 * 3], floats[$0 * 3 + 1], floats[$0 * 3 + 2]) }
    }

    /// Index triples.
    public func faceArray() -> [SIMD3<UInt32>] {
        let indices: [UInt32] = faces.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self).prefix(faceCount * 3)) }
        return (0..<faceCount).map { SIMD3(indices[$0 * 3], indices[$0 * 3 + 1], indices[$0 * 3 + 2]) }
    }

    /// One class per face.
    public func classArray() -> [UInt8] { Array(classes.prefix(faceCount)) }
}

/// Mesh classification values as written to `.classes` and coloured into `mesh.ply`. The raw
/// values are ARKit's `ARMeshClassification.rawValue`; the package never imports ARKit.
public enum MeshClassification: UInt8, Sendable, CaseIterable, Codable, Equatable {
    case none = 0
    case wall = 1
    case floor = 2
    case ceiling = 3
    case table = 4
    case seat = 5
    case window = 6
    case door = 7
}

// MARK: - simd helpers

extension SIMD4 where Scalar == Float {
    public var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}

extension simd_float4x4 {
    /// Column-major flattening, the on-disk convention.
    public var columnMajorArray: [Float] {
        [columns.0.x, columns.0.y, columns.0.z, columns.0.w,
         columns.1.x, columns.1.y, columns.1.z, columns.1.w,
         columns.2.x, columns.2.y, columns.2.z, columns.2.w,
         columns.3.x, columns.3.y, columns.3.z, columns.3.w]
    }

    /// Inverse of `columnMajorArray`; `nil` unless `values.count == 16`.
    public init?(columnMajorArray values: [Float]) {
        guard values.count == 16 else { return nil }
        self.init(columns: (SIMD4(values[0], values[1], values[2], values[3]),
                            SIMD4(values[4], values[5], values[6], values[7]),
                            SIMD4(values[8], values[9], values[10], values[11]),
                            SIMD4(values[12], values[13], values[14], values[15])))
    }

    public var translation: SIMD3<Float> { columns.3.xyz }

    public func transformPoint(_ p: SIMD3<Float>) -> SIMD3<Float> {
        (self * SIMD4<Float>(p, 1)).xyz
    }

    /// The angle in degrees between where this pose looks and where `other` looks, both being
    /// camera-to-world matrices whose forward is −Z.
    ///
    /// `FrameGate` needs this to decide whether the camera turned far enough to write a frame,
    /// and the gate applies to a real ARKit capture, so the maths lives here in the core rather
    /// than with the synthetic camera that also uses it.
    public func forwardAngleDegrees(to other: simd_float4x4) -> Float {
        let a = -columns.2.xyz, b = -other.columns.2.xyz
        let c = max(-1, min(1, simd_dot(simd_normalize(a), simd_normalize(b))))
        return acos(c) * 180 / .pi
    }
}

extension simd_float3x3 {
    /// Column-major flattening, the on-disk convention.
    public var columnMajorArray: [Float] {
        [columns.0.x, columns.0.y, columns.0.z,
         columns.1.x, columns.1.y, columns.1.z,
         columns.2.x, columns.2.y, columns.2.z]
    }

    /// Inverse of `columnMajorArray`; `nil` unless `values.count == 9`.
    public init?(columnMajorArray values: [Float]) {
        guard values.count == 9 else { return nil }
        self.init(columns: (SIMD3(values[0], values[1], values[2]),
                            SIMD3(values[3], values[4], values[5]),
                            SIMD3(values[6], values[7], values[8])))
    }
}
