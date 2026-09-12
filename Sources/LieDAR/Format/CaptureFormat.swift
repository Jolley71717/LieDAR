import Foundation

/// The on-disk capture format — names, extensions, encoders and the class-colour table. The
/// prose contract is `docs/CAPTURE_FORMAT.md`; this type is its executable half. Everything here
/// is readable on a Mac with no ARKit: raw little-endian arrays with no header, shapes in the
/// JSON files beside them, metres everywhere, ARKit's world frame (right-handed, +Y up).
public enum CaptureFormat {
    /// The version this package writes. See `docs/CAPTURE_FORMAT.md` § Versions.
    public static let formatVersion = 2
    /// Versions the reader accepts.
    public static let readableFormatVersions: ClosedRange<Int> = 1...2

    public static let manifestFile = "capture.json"
    public static let framesDirectory = "frames"
    public static let meshDirectory = "mesh"
    public static let anchorsFile = "anchors.json"
    public static let mergedPLYFile = "mesh.ply"
    /// Written only by an ARKit-backed source; never by this package's recorder.
    public static let worldMapFile = "worldmap.bin"

    public static let depthExtension = "depth"
    public static let confidenceExtension = "conf"
    public static let colorExtension = "jpg"
    public static let frameMetaExtension = "json"
    public static let verticesExtension = "vertices"
    public static let facesExtension = "faces"
    public static let classesExtension = "classes"

    /// `000123`-style base name for frame `index` (six digits, zero padded, no extension).
    public static func frameBaseName(_ index: Int) -> String {
        precondition(index >= 0, "frame index must be non-negative")
        let digits = String(index)
        return digits.count >= 6 ? digits : String(repeating: "0", count: 6 - digits.count) + digits
    }

    /// The frame index a base name encodes, or `nil` for anything that is not six or more digits.
    public static func frameIndex(fromBaseName name: String) -> Int? {
        guard name.count >= 6, name.allSatisfy(\.isNumber) else { return nil }
        return Int(name)
    }

    /// Counts what is actually on disk. Cheap — two directory listings, no file contents. A
    /// missing folder counts as zero rather than throwing. A frame counts only once its `.json`
    /// exists, because the recorder writes that last; an anchor counts by its `.vertices` file.
    /// Provenance: extracted from the first consumer's private implementation by the same
    /// author; MIT here.
    public static func contents(of folder: URL) -> CaptureContents {
        let manager = FileManager.default
        var contents = CaptureContents()
        let frames = (try? manager.contentsOfDirectory(atPath: folder.appendingPathComponent(framesDirectory).path)) ?? []
        contents.frameCount = frames.filter { ($0 as NSString).pathExtension == frameMetaExtension }.count
        let mesh = (try? manager.contentsOfDirectory(atPath: folder.appendingPathComponent(meshDirectory).path)) ?? []
        contents.meshAnchorCount = mesh.filter { ($0 as NSString).pathExtension == verticesExtension }.count
        return contents
    }

    /// Whether a finished capture folder is worth keeping. Provenance: extracted from the first
    /// consumer's private implementation by the same author; MIT here.
    public static func disposition(of contents: CaptureContents) -> CaptureDisposition {
        if contents.isEmpty { return .discardEmpty }
        if contents.meshAnchorCount == 0 { return .keepWithoutMesh }
        return .keep
    }

    /// RGB used in `mesh.ply` for each `MeshClassification.rawValue`. Exact values, so a reader
    /// can map the colour back to the class. Provenance: the first consumer's private colour
    /// table, extracted by the same author; MIT here.
    public static func classificationColor(_ rawValue: UInt8) -> (r: UInt8, g: UInt8, b: UInt8) {
        switch rawValue {
        case 1: return (230, 138, 46)   // wall
        case 2: return (46, 138, 230)   // floor
        case 3: return (46, 200, 120)   // ceiling
        case 4: return (200, 200, 60)   // table
        case 5: return (200, 60, 200)   // seat
        case 6: return (60, 220, 220)   // window
        case 7: return (220, 60, 60)    // door
        default: return (128, 128, 128) // none
        }
    }

    /// The class a `mesh.ply` vertex colour encodes; `.none` for any colour not in the table.
    public static func classification(ofColor r: UInt8, _ g: UInt8, _ b: UInt8) -> MeshClassification {
        MeshClassification.allCases.first { classificationColor($0.rawValue) == (r, g, b) } ?? .none
    }

    /// Fresh encoder with the format's settings: ISO 8601 dates, pretty printed, sorted keys —
    /// so every JSON file in a folder is byte-stable across writers.
    public static func makeJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    public static func makeJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// `capture.json`. Written last by the recorder, so its presence means the capture finished.
/// Field names are the on-disk contract.
public struct CaptureManifest: Codable, Sendable, Equatable {
    /// `CaptureFormat.formatVersion` when written by this package.
    public var formatVersion: Int
    /// Hardware identifier of the producing device (`"iPhone15,2"`), or a synthetic marker such
    /// as `"LieDAR-synthetic"` for generated captures. Never a real model string in a public fixture.
    public var deviceModel: String
    /// OS version of the producing device, or a synthetic marker. The key is `iosVersion` for
    /// compatibility with the first consumer's files.
    public var iosVersion: String
    public var startedAt: Date
    public var endedAt: Date
    /// Frames ACCEPTED for writing. Truth is the folder — a frame whose write failed is absent
    /// on disk; count `frames/*.json` to know what is really there.
    public var frameCount: Int
    public var meshAnchorCount: Int
    public var totalVertices: Int
    public var totalFaces: Int
    /// Whether `worldmap.bin` exists. Always `false` for captures this package writes.
    public var worldMapSaved: Bool
    public var notes: String
    /// Frames the session observed with `.normal` tracking while running (written or not).
    /// Absent in version 1 files; decoded as 0.
    public var normalTrackingFrameCount: Int
    /// Frames the session observed while running, any tracking state. Absent in version 1; 0.
    public var totalTrackingFrameCount: Int

    public init(formatVersion: Int = CaptureFormat.formatVersion,
                deviceModel: String,
                iosVersion: String,
                startedAt: Date,
                endedAt: Date,
                frameCount: Int,
                meshAnchorCount: Int,
                totalVertices: Int,
                totalFaces: Int,
                worldMapSaved: Bool = false,
                notes: String = "",
                normalTrackingFrameCount: Int = 0,
                totalTrackingFrameCount: Int = 0) {
        self.formatVersion = formatVersion
        self.deviceModel = deviceModel
        self.iosVersion = iosVersion
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.frameCount = frameCount
        self.meshAnchorCount = meshAnchorCount
        self.totalVertices = totalVertices
        self.totalFaces = totalFaces
        self.worldMapSaved = worldMapSaved
        self.notes = notes
        self.normalTrackingFrameCount = normalTrackingFrameCount
        self.totalTrackingFrameCount = totalTrackingFrameCount
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, deviceModel, iosVersion, startedAt, endedAt, frameCount, meshAnchorCount
        case totalVertices, totalFaces, worldMapSaved, notes, normalTrackingFrameCount, totalTrackingFrameCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        deviceModel = try c.decode(String.self, forKey: .deviceModel)
        iosVersion = try c.decode(String.self, forKey: .iosVersion)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decode(Date.self, forKey: .endedAt)
        frameCount = try c.decode(Int.self, forKey: .frameCount)
        meshAnchorCount = try c.decode(Int.self, forKey: .meshAnchorCount)
        totalVertices = try c.decode(Int.self, forKey: .totalVertices)
        totalFaces = try c.decode(Int.self, forKey: .totalFaces)
        worldMapSaved = try c.decode(Bool.self, forKey: .worldMapSaved)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        normalTrackingFrameCount = try c.decodeIfPresent(Int.self, forKey: .normalTrackingFrameCount) ?? 0
        totalTrackingFrameCount = try c.decodeIfPresent(Int.self, forKey: .totalTrackingFrameCount) ?? 0
    }
}

/// One entry of `mesh/anchors.json`.
public struct MeshAnchorMeta: Codable, Sendable, Equatable {
    /// `UUID.uuidString` (upper-case, hyphenated); also the base name of the three binary files.
    public var identifier: String
    /// 16 floats, column-major anchor-to-world.
    public var transform: [Float]
    public var vertexCount: Int
    public var faceCount: Int
    /// `"<identifier>.vertices"` — a plain file name inside `mesh/`, never a path.
    public var verticesFile: String
    public var facesFile: String
    public var classesFile: String

    public init(identifier: String, transform: [Float], vertexCount: Int, faceCount: Int,
                verticesFile: String, facesFile: String, classesFile: String) {
        self.identifier = identifier
        self.transform = transform
        self.vertexCount = vertexCount
        self.faceCount = faceCount
        self.verticesFile = verticesFile
        self.facesFile = facesFile
        self.classesFile = classesFile
    }

    /// The entry the recorder writes for `anchor`.
    public init(_ anchor: MeshAnchorPayload) {
        let id = anchor.id.uuidString
        self.init(identifier: id,
                  transform: anchor.transform.columnMajorArray,
                  vertexCount: anchor.vertexCount,
                  faceCount: anchor.faceCount,
                  verticesFile: "\(id).\(CaptureFormat.verticesExtension)",
                  facesFile: "\(id).\(CaptureFormat.facesExtension)",
                  classesFile: "\(id).\(CaptureFormat.classesExtension)")
    }
}

/// What a capture folder actually holds on disk.
public struct CaptureContents: Equatable, Sendable {
    public var frameCount = 0
    public var meshAnchorCount = 0

    public init(frameCount: Int = 0, meshAnchorCount: Int = 0) {
        self.frameCount = frameCount
        self.meshAnchorCount = meshAnchorCount
    }

    /// Nothing usable was captured: no complete frame and no mesh anchor.
    public var isEmpty: Bool { frameCount == 0 && meshAnchorCount == 0 }
}

/// What to do with a finished capture folder.
public enum CaptureDisposition: Equatable, Sendable {
    /// Frames and a mesh — keep it.
    case keep
    /// Frames but no mesh anchor. Still usable: depth frames alone drive an offline
    /// reconstruction. The consumer should warn.
    case keepWithoutMesh
    /// Neither frames nor mesh. Persisting this leaves an empty scan behind; delete it.
    case discardEmpty
}

/// Totals over a written mesh snapshot.
public struct MeshSnapshotSummary: Sendable, Equatable {
    public var anchorCount = 0
    public var totalVertices = 0
    public var totalFaces = 0

    public init(anchorCount: Int = 0, totalVertices: Int = 0, totalFaces: Int = 0) {
        self.anchorCount = anchorCount
        self.totalVertices = totalVertices
        self.totalFaces = totalFaces
    }
}
