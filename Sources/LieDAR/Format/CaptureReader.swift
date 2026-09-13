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
        /// A file named in `anchors.json` does not resolve to a regular file inside `mesh/`:
        /// the name is not a plain name, or it resolves through a symlink to somewhere else, or
        /// what is there is a directory rather than a file.
        case unsafeFileName(String)
        /// A count in `anchors.json` is negative, or large enough that the byte count it implies
        /// overflows.
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

    /// Whether `capture.json` exists, which is the folder-level completeness marker.
    public var isFinished: Bool {
        FileManager.default.fileExists(atPath: folderURL.appendingPathComponent(CaptureFormat.manifestFile).path)
    }

    /// Decodes `capture.json`. Throws `unsupportedFormatVersion` for a version outside
    /// `CaptureFormat.readableFormatVersions`.
    public func manifest() throws -> CaptureManifest {
        let url = folderURL.appendingPathComponent(CaptureFormat.manifestFile)
        guard let data = regularFileData(url) else {
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

    /// Indices that have binary files but no `.json`, meaning frames a writer was interrupted on.
    public func incompleteFrameIndices() -> [Int] { frameStatuses().filter { !$0.isComplete }.map(\.index) }

    public func frameURL(_ index: Int, extension ext: String) -> URL {
        framesURL.appendingPathComponent(CaptureFormat.frameBaseName(index)).appendingPathExtension(ext)
    }

    /// Decodes `frames/NNNNNN.json`. Throws `frameIncomplete` when the file is absent.
    public func frameMeta(_ index: Int) throws -> FrameMeta {
        let url = frameURL(index, extension: CaptureFormat.frameMetaExtension)
        guard let data = regularFileData(url) else { throw ReadError.frameIncomplete(index) }
        do {
            let meta = try CaptureFormat.makeJSONDecoder().decode(FrameMeta.self, from: data)
            guard meta.cameraTransform.count == 16 else { throw ReadError.badFrameMeta(index, "cameraTransform has \(meta.cameraTransform.count) values, not 16") }
            guard meta.intrinsics.count == 9 else { throw ReadError.badFrameMeta(index, "intrinsics has \(meta.intrinsics.count) values, not 9") }
            // A capture folder is untrusted input, and every reader of `depthResolution`
            // multiplies it. A width of −4 made the byte count −64, slipped past the
            // `data.count >= bytes` check and trapped in `Data.prefix`; a width of 2^62 trapped
            // the multiply itself. Both are rejected here, once, for every caller.
            let size = meta.depthResolution
            guard size.width > 0, size.height > 0 else {
                throw ReadError.badFrameMeta(index, "depthResolution is \(size.width) × \(size.height), which is not a positive size")
            }
            guard size.width.multipliedReportingOverflow(by: size.height).overflow == false,
                  (size.width * size.height).multipliedReportingOverflow(by: 4).overflow == false else {
                throw ReadError.badFrameMeta(index, "depthResolution \(size.width) × \(size.height) needs more bytes than can be counted")
            }
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
        regularFileData(frameURL(index, extension: CaptureFormat.colorExtension))
    }

    // MARK: Mesh

    /// Decodes `mesh/anchors.json`; `[]` when the file is absent (no mesh was captured).
    public func anchors() throws -> [MeshAnchorMeta] {
        let url = meshURL.appendingPathComponent(CaptureFormat.anchorsFile)
        guard let data = regularFileData(url) else { return [] }
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
        // Both counts come from the file and both are multiplied. Unchecked, `Int.max` vertices
        // trapped the multiply before any of the length checks below could run. A count that is
        // merely absurd does not overflow and stays a plain `shortFile`.
        let vertexBytes = meta.vertexCount.multipliedReportingOverflow(by: MeshAnchorPayload.bytesPerVertex)
        let faceBytes = meta.faceCount.multipliedReportingOverflow(by: MeshAnchorPayload.bytesPerFace)
        guard !vertexBytes.overflow, !faceBytes.overflow else { throw ReadError.badCount(meta.identifier) }
        guard let transform = simd_float4x4(columnMajorArray: meta.transform) else {
            throw ReadError.badAnchors("anchor \(meta.identifier) transform has \(meta.transform.count) values, not 16")
        }
        // The identifier is the anchor's identity, and a reader that quietly minted a fresh UUID
        // for one it could not parse made two reads of the same folder disagree, which loses
        // track of an anchor in anything that keys on it.
        guard let id = UUID(uuidString: meta.identifier) else {
            throw ReadError.badAnchors("anchor identifier \"\(meta.identifier)\" is not a UUID")
        }
        let vertices = try readExact(meshURL.appendingPathComponent(meta.verticesFile), bytes: vertexBytes.partialValue)
        let faces = try readExact(meshURL.appendingPathComponent(meta.facesFile), bytes: faceBytes.partialValue)
        let classes = try readExact(meshURL.appendingPathComponent(meta.classesFile), bytes: meta.faceCount)
        return MeshAnchorPayload(id: id, transform: transform,
                                 vertices: vertices, faces: faces, classes: classes,
                                 vertexCount: meta.vertexCount, faceCount: meta.faceCount)
    }

    // MARK: Helpers

    /// Reads exactly `bytes` from `url`, which must resolve to a regular file inside the capture
    /// folder.
    private func readExact(_ url: URL, bytes: Int) throws -> Data {
        // `bytes` is derived from a count in the file. Every caller checks it, and this is the
        // backstop: a negative length passes `data.count >= bytes` and then traps in `prefix`.
        let name = url.lastPathComponent
        guard bytes >= 0 else { throw ReadError.badCount(name) }
        let resolved = try regularFileInsideCapture(url)
        guard let data = FileManager.default.contents(atPath: resolved.path) else { throw ReadError.missingFile(name) }
        guard data.count >= bytes else { throw ReadError.shortFile(name, expected: bytes, got: data.count) }
        return data.count == bytes ? data : data.prefix(bytes)
    }

    /// Checks that `url` is a regular file sitting inside the capture folder, and returns it.
    ///
    /// The name check in `anchor(_:)` reads a string, and a symlink's own name is a perfectly
    /// legal plain name, so it passed; `FileManager.contents(atPath:)` then followed the link and
    /// read bytes from outside the folder. Zip archives and AirDropped folders both carry
    /// symlinks, so a capture that arrives from anywhere can hold one.
    ///
    /// **A symlink is refused even when it points at a file inside the folder.** Nothing that
    /// writes a LieDAR capture emits one, so allowing it buys no compatibility, and "every file
    /// in a capture is a regular file" is an invariant that can be stated and tested in one line,
    /// where "resolves to somewhere under the folder" cannot. It is also the safer of the two: a
    /// link can be re-pointed after it has been checked, and a regular file cannot.
    ///
    /// The mechanism is `attributesOfItem`, which reports on the link itself rather than its
    /// target (probed, not assumed), so anything that is not a regular file is refused before it
    /// is opened. The resolved-parent comparison after it is redundant for a plain name that has
    /// already passed the type check, and is kept so that relaxing the type check later cannot
    /// silently reopen the hole. Both sides are resolved so that `/var` against `/private/var`
    /// does not read as an escape.
    ///
    /// What it still misses. The check and the read are two calls on a path, so an attacker with
    /// write access to the folder could swap a regular file for a link in between and be followed
    /// (time-of-check to time-of-use). That gap is left open deliberately: closing it means
    /// opening the file with `O_NOFOLLOW` and reading through the descriptor rather than through
    /// `FileManager`, and anyone who can win that race can already choose what the reader parses
    /// by writing the file's contents. A hard link to a file outside the folder has no path to
    /// resolve and reads as an ordinary file. Reading a capture out of a directory that someone
    /// else can write to is not made safe by any of this.
    private func regularFileInsideCapture(_ url: URL) throws -> URL {
        let name = url.lastPathComponent
        guard let type = fileType(url) else { throw ReadError.missingFile(name) }
        guard type == .typeRegular else { throw ReadError.unsafeFileName(name) }
        let root = folderURL.resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        let boundary = root.hasSuffix("/") ? root : root + "/"
        guard resolved.hasPrefix(boundary) else { throw ReadError.unsafeFileName(name) }
        return url
    }

    /// The type of the item at `url` without following a link, or `nil` when nothing is there.
    private func fileType(_ url: URL) -> FileAttributeType? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
    }

    /// Contents of `url` only when it is a regular file inside the capture folder; `nil` otherwise.
    ///
    /// The reads that do not go through `readExact` need the same guard. Their *names* are safe,
    /// because `manifest`, `frameMeta` and `colorJPEG` build the path from a constant or a frame
    /// index rather than from anything in the file. The *item at that name* is not: a zip can
    /// carry `frames/000000.jpg` as a symlink just as easily as it can carry
    /// `mesh/<uuid>.vertices` as one, and `colorJPEG` hands its bytes straight back to the caller.
    private func regularFileData(_ url: URL) -> Data? {
        guard fileType(url) == .typeRegular else { return nil }
        guard (try? regularFileInsideCapture(url)) != nil else { return nil }
        return FileManager.default.contents(atPath: url.path)
    }
}
