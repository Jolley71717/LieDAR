import Foundation
import simd

/// Reads a capture folder written in `CaptureFormat`. Lazy and cheap: nothing is loaded until
/// asked for, and each call reads exactly the files it names.
public struct CaptureReader: Sendable {
    public enum ReadError: Error, Equatable, Sendable {
        case missingManifest(String)
        case unsupportedFormatVersion(Int)
        case frameIncomplete(Int)
        case missingFile(String)
        case shortFile(String, expected: Int, got: Int)
        case badFrameMeta(Int, String)
        case badAnchors(String)
        /// A file name in `anchors.json` is not a plain name inside `mesh/`.
        case unsafeFileName(String)
        case badCount(String)
    }

    /// One frame index and which of its files exist. `isComplete` is the format's completeness
    /// rule: the `.json` is written last, so the frame is complete exactly when it exists.
    public struct FrameStatus: Equatable, Sendable {
        public var index: Int
        public var hasDepth: Bool
        public var hasConfidence: Bool
        public var hasColor: Bool
        public var hasMeta: Bool

        public var isComplete: Bool { hasMeta }
    }

    public let folderURL: URL
    public var framesURL: URL { folderURL.appendingPathComponent(CaptureFormat.framesDirectory, isDirectory: true) }
    public var meshURL: URL { folderURL.appendingPathComponent(CaptureFormat.meshDirectory, isDirectory: true) }

    public init(folderURL: URL) {
        self.folderURL = folderURL
    }

    // MARK: Manifest

    /// Whether `capture.json` exists — the folder-level completeness marker.
    public var isFinished: Bool {
        FileManager.default.fileExists(atPath: folderURL.appendingPathComponent(CaptureFormat.manifestFile).path)
    }

    /// Decodes `capture.json`. Throws `unsupportedFormatVersion` for a version outside
    /// `CaptureFormat.readableFormatVersions`.
    public func manifest() throws -> CaptureManifest {
        let url = folderURL.appendingPathComponent(CaptureFormat.manifestFile)
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw ReadError.missingManifest(url.path)
        }
        let manifest = try CaptureFormat.makeJSONDecoder().decode(CaptureManifest.self, from: data)
        guard CaptureFormat.readableFormatVersions.contains(manifest.formatVersion) else {
            throw ReadError.unsupportedFormatVersion(manifest.formatVersion)
        }
        return manifest
    }

    /// What is on disk, by directory listing (`CaptureFormat.contents(of:)`).
    public var contents: CaptureContents { CaptureFormat.contents(of: folderURL) }

    // MARK: Frames

    /// Every frame index that has at least one file, with which files it has, ascending.
    public func frameStatuses() -> [FrameStatus] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: framesURL.path)) ?? []
        var byIndex: [Int: FrameStatus] = [:]
        for name in names {
            let ns = name as NSString
            guard let index = CaptureFormat.frameIndex(fromBaseName: ns.deletingPathExtension) else { continue }
            var status = byIndex[index] ?? FrameStatus(index: index, hasDepth: false, hasConfidence: false, hasColor: false, hasMeta: false)
            switch ns.pathExtension {
            case CaptureFormat.depthExtension: status.hasDepth = true
            case CaptureFormat.confidenceExtension: status.hasConfidence = true
            case CaptureFormat.colorExtension: status.hasColor = true
            case CaptureFormat.frameMetaExtension: status.hasMeta = true
            default: continue
            }
            byIndex[index] = status
        }
        return byIndex.values.sorted { $0.index < $1.index }
    }

    /// Indices of complete frames (those with a `.json`), ascending.
    public func completeFrameIndices() -> [Int] { frameStatuses().filter(\.isComplete).map(\.index) }

    /// Indices that have binary files but no `.json` — frames a writer was interrupted on.
    public func incompleteFrameIndices() -> [Int] { frameStatuses().filter { !$0.isComplete }.map(\.index) }

    public func frameURL(_ index: Int, extension ext: String) -> URL {
        framesURL.appendingPathComponent(CaptureFormat.frameBaseName(index)).appendingPathExtension(ext)
    }

    /// Decodes `frames/NNNNNN.json`. Throws `frameIncomplete` when the file is absent.
    public func frameMeta(_ index: Int) throws -> FrameMeta {
        let url = frameURL(index, extension: CaptureFormat.frameMetaExtension)
        guard let data = FileManager.default.contents(atPath: url.path) else { throw ReadError.frameIncomplete(index) }
        do {
            let meta = try CaptureFormat.makeJSONDecoder().decode(FrameMeta.self, from: data)
            guard meta.cameraTransform.count == 16 else { throw ReadError.badFrameMeta(index, "cameraTransform has \(meta.cameraTransform.count) values, not 16") }
            guard meta.intrinsics.count == 9 else { throw ReadError.badFrameMeta(index, "intrinsics has \(meta.intrinsics.count) values, not 9") }
            return meta
        } catch let error as ReadError {
            throw error
        } catch {
            throw ReadError.badFrameMeta(index, String(describing: error))
        }
    }

    /// The depth plane of a complete frame, shaped by its meta's `depthResolution`.
    public func depth(_ index: Int) throws -> Plane<Float32> {
        let meta = try frameMeta(index)
        let data = try readExact(frameURL(index, extension: CaptureFormat.depthExtension),
                                 bytes: meta.depthResolution.width * meta.depthResolution.height * 4)
        return Plane(data: data, width: meta.depthResolution.width, height: meta.depthResolution.height,
                     bytesPerRow: meta.depthResolution.width * 4)
    }

    /// The confidence plane of a complete frame, or `nil` when the frame has none.
    public func confidence(_ index: Int) throws -> Plane<UInt8>? {
        let meta = try frameMeta(index)
        let url = frameURL(index, extension: CaptureFormat.confidenceExtension)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try readExact(url, bytes: meta.depthResolution.width * meta.depthResolution.height)
        return Plane(data: data, width: meta.depthResolution.width, height: meta.depthResolution.height,
                     bytesPerRow: meta.depthResolution.width)
    }

    /// The raw JPEG bytes of a frame's colour image, or `nil` when it has none.
    public func colorJPEG(_ index: Int) -> Data? {
        FileManager.default.contents(atPath: frameURL(index, extension: CaptureFormat.colorExtension).path)
    }

    // MARK: Mesh

    /// Decodes `mesh/anchors.json`; `[]` when the file is absent (no mesh was captured).
    public func anchors() throws -> [MeshAnchorMeta] {
        let url = meshURL.appendingPathComponent(CaptureFormat.anchorsFile)
        guard let data = FileManager.default.contents(atPath: url.path) else { return [] }
        do {
            return try CaptureFormat.makeJSONDecoder().decode([MeshAnchorMeta].self, from: data)
        } catch {
            throw ReadError.badAnchors(String(describing: error))
        }
    }

    /// Loads one anchor's three files as a payload, checking every length against its meta.
    public func anchor(_ meta: MeshAnchorMeta) throws -> MeshAnchorPayload {
        for name in [meta.verticesFile, meta.facesFile, meta.classesFile] {
            guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), name != ".", name != ".." else {
                throw ReadError.unsafeFileName(name)
            }
        }
        guard meta.vertexCount >= 0, meta.faceCount >= 0 else { throw ReadError.badCount(meta.identifier) }
        guard let transform = simd_float4x4(columnMajorArray: meta.transform) else {
            throw ReadError.badAnchors("anchor \(meta.identifier) transform has \(meta.transform.count) values, not 16")
        }
        let vertices = try readExact(meshURL.appendingPathComponent(meta.verticesFile),
                                     bytes: meta.vertexCount * MeshAnchorPayload.bytesPerVertex)
        let faces = try readExact(meshURL.appendingPathComponent(meta.facesFile),
                                  bytes: meta.faceCount * MeshAnchorPayload.bytesPerFace)
        let classes = try readExact(meshURL.appendingPathComponent(meta.classesFile), bytes: meta.faceCount)
        return MeshAnchorPayload(id: UUID(uuidString: meta.identifier) ?? UUID(), transform: transform,
                                 vertices: vertices, faces: faces, classes: classes,
                                 vertexCount: meta.vertexCount, faceCount: meta.faceCount)
    }

    // MARK: Helpers

    private func readExact(_ url: URL, bytes: Int) throws -> Data {
        guard let data = FileManager.default.contents(atPath: url.path) else { throw ReadError.missingFile(url.lastPathComponent) }
        guard data.count >= bytes else { throw ReadError.shortFile(url.lastPathComponent, expected: bytes, got: data.count) }
        return data.count == bytes ? data : data.prefix(bytes)
    }
}
