import Foundation
import simd

extension RoomModel {
    public enum OBJError: Error, Equatable, Sendable {
        case badVertex(line: Int)
        case badFace(line: Int)
        case indexOutOfRange(line: Int, index: Int)
        case noTriangles
    }

    /// Loads an ASCII Wavefront OBJ. `v` lines are vertices (metres, +Y up), `f` lines are
    /// triangles or quads (quads are split into two triangles; `v/vt/vn` forms and negative
    /// indices are accepted). A face's class comes from the most recent `o`, `g` or `usemtl`
    /// name: the first of `wall`, `floor`, `ceiling`, `door`, `window`, `table`, `seat`/`chair`
    /// it contains (case-insensitive) wins; anything else is `none`. Everything else in the
    /// file is ignored. USDZ is not read.
    public init(objText: String) throws {
        var vertices: [SIMD3<Float>] = []
        var triangles: [SIMD3<UInt32>] = []
        var classes: [MeshClassification] = []
        var current = MeshClassification.none

        for (offset, rawLine) in objText.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineNumber = offset + 1
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let keyword = fields.first else { continue }
            switch keyword {
            case "v":
                guard fields.count >= 4, let x = Float(fields[1]), let y = Float(fields[2]), let z = Float(fields[3]) else {
                    throw OBJError.badVertex(line: lineNumber)
                }
                vertices.append(SIMD3(x, y, z))
            case "f":
                guard fields.count >= 4 else { throw OBJError.badFace(line: lineNumber) }
                var indices: [UInt32] = []
                for field in fields.dropFirst() {
                    let first = field.split(separator: "/", omittingEmptySubsequences: false)[0]
                    guard let raw = Int(first), raw != 0 else { throw OBJError.badFace(line: lineNumber) }
                    let resolved = raw > 0 ? raw - 1 : vertices.count + raw
                    guard resolved >= 0, resolved < vertices.count else {
                        throw OBJError.indexOutOfRange(line: lineNumber, index: raw)
                    }
                    indices.append(UInt32(resolved))
                }
                // Fan triangulation handles triangles, quads and larger convex polygons alike.
                for k in 1..<(indices.count - 1) {
                    triangles.append(SIMD3(indices[0], indices[k], indices[k + 1]))
                    classes.append(current)
                }
            case "o", "g", "usemtl":
                current = Self.classification(fromName: fields.dropFirst().joined(separator: " "))
            default:
                continue
            }
        }
        guard !triangles.isEmpty else { throw OBJError.noTriangles }
        self.init(vertices: vertices, triangles: triangles, classes: classes)
    }

    /// The class a group/material name implies.
    public static func classification(fromName name: String) -> MeshClassification {
        let lower = name.lowercased()
        let table: [(String, MeshClassification)] = [
            ("wall", .wall), ("floor", .floor), ("ceiling", .ceiling), ("door", .door),
            ("window", .window), ("table", .table), ("seat", .seat), ("chair", .seat),
        ]
        for (needle, cls) in table where lower.contains(needle) { return cls }
        return .none
    }

    /// The model as ASCII OBJ, one `g` group per class, so a room can be written out, edited
    /// and loaded back with `init(objText:)`. Vertices print in shortest round-trip form.
    public func objText() -> String {
        var out = "# LieDAR RoomModel, metres, +Y up\n"
        for v in vertices { out += "v \(v.x) \(v.y) \(v.z)\n" }
        var byClass: [MeshClassification: [SIMD3<UInt32>]] = [:]
        for (t, c) in zip(triangles, classes) { byClass[c, default: []].append(t) }
        for cls in MeshClassification.allCases {
            guard let faces = byClass[cls] else { continue }
            out += "g \(Self.groupName(cls))\n"
            for f in faces { out += "f \(f.x + 1) \(f.y + 1) \(f.z + 1)\n" }
        }
        return out
    }

    static func groupName(_ cls: MeshClassification) -> String {
        switch cls {
        case .none: return "none"
        case .wall: return "wall"
        case .floor: return "floor"
        case .ceiling: return "ceiling"
        case .table: return "table"
        case .seat: return "seat"
        case .window: return "window"
        case .door: return "door"
        }
    }
}
