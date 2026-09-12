import Foundation
import simd

// Provenance: extracted from the first consumer's private raw-capture writer by the same author;
// relicensed MIT here. The text layout it produces is the format contract.

/// Accumulates world-space geometry and renders one ASCII PLY with per-vertex colours — the
/// majority classification of the faces touching each vertex, ties to the lowest class. The
/// exact text layout is part of the format (`docs/CAPTURE_FORMAT.md` § mesh.ply).
struct PLYBuilder {
    private static let classCount = 8

    private var vertices: [SIMD3<Float>] = []
    private var vertexClasses: [UInt8] = []
    private var faces: [UInt32] = []

    var vertexCount: Int { vertices.count }
    var faceCount: Int { faces.count / 3 }

    mutating func append(_ anchor: MeshAnchorPayload) {
        let base = UInt32(vertices.count)
        let vertexCount = anchor.vertexCount
        let localVertices = anchor.vertexArray()
        let indices: [UInt32] = anchor.faces.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self).prefix(anchor.faceCount * 3)) }
        let classes = anchor.classArray()

        vertices.reserveCapacity(vertices.count + vertexCount)
        for local in localVertices {
            vertices.append(anchor.transform.transformPoint(local))
        }

        // Vote: one histogram row per vertex, one vote per incident face.
        var votes = [UInt16](repeating: 0, count: vertexCount * Self.classCount)
        for f in 0..<anchor.faceCount {
            let cls = Int(min(f < classes.count ? classes[f] : 0, UInt8(Self.classCount - 1)))
            for k in 0..<3 {
                let v = Int(indices[f * 3 + k])
                if v < vertexCount {
                    votes[v * Self.classCount + cls] &+= 1
                }
            }
        }
        vertexClasses.reserveCapacity(vertexClasses.count + vertexCount)
        for v in 0..<vertexCount {
            var best = 0
            var bestVotes: UInt16 = 0
            for cls in 0..<Self.classCount {
                let n = votes[v * Self.classCount + cls]
                if n > bestVotes {
                    bestVotes = n
                    best = cls
                }
            }
            vertexClasses.append(UInt8(best))
        }

        faces.reserveCapacity(faces.count + indices.count)
        for index in indices {
            faces.append(base + index)
        }
    }

    /// The complete PLY text. Floats use Swift's shortest round-trip decimal form.
    func render() -> String {
        let faceCount = self.faceCount
        var out = ""
        out.reserveCapacity(vertices.count * 48 + faceCount * 24 + 512)
        out += "ply\nformat ascii 1.0\n"
        out += "comment LieDAR raw capture, world space, metres, +Y up\n"
        out += "comment vertex colour = majority mesh classification (see CaptureFormat.classificationColor)\n"
        out += "element vertex \(vertices.count)\n"
        out += "property float x\nproperty float y\nproperty float z\n"
        out += "property uchar red\nproperty uchar green\nproperty uchar blue\n"
        out += "element face \(faceCount)\n"
        out += "property list uchar int vertex_indices\n"
        out += "end_header\n"
        for (i, v) in vertices.enumerated() {
            let color = CaptureFormat.classificationColor(vertexClasses[i])
            out += "\(v.x) \(v.y) \(v.z) \(color.r) \(color.g) \(color.b)\n"
        }
        for f in 0..<faceCount {
            out += "3 \(faces[f * 3]) \(faces[f * 3 + 1]) \(faces[f * 3 + 2])\n"
        }
        return out
    }
}
