import Foundation
import LieDAR

/// What a finished capture folder actually contains, read back through the package's own
/// `CaptureReader` rather than remembered from the run. If the writer and the reader disagree,
/// this screen is where it shows.
struct CaptureDetail: Sendable, Equatable {
    var frameFileCount = 0
    var meshFileCount = 0
    var frameBytes = 0
    var meshBytes = 0
    var totalBytes = 0
    /// From `capture.json`, not from the directory listing.
    var manifestFrameCount = 0
    var anchorCount = 0
    var faceCount = 0
    /// Faces the source left as `MeshClassification.none`. The degradation model's fingerprint:
    /// zero on a clean room, roughly a third of the mesh at the suite default.
    var unlabelledFaceCount = 0

    var unlabelledPercent: Int {
        faceCount == 0 ? 0 : Int((Double(unlabelledFaceCount) / Double(faceCount) * 100).rounded())
    }

    /// Reads a folder. Cheap enough to run on a background task at screen-open time.
    static func read(_ folder: URL) -> CaptureDetail {
        var detail = CaptureDetail()
        let reader = CaptureReader(folderURL: folder)
        detail.frameFileCount = fileCount(in: reader.framesURL)
        detail.meshFileCount = fileCount(in: reader.meshURL)
        detail.frameBytes = CaptureStore.byteCount(of: reader.framesURL)
        detail.meshBytes = CaptureStore.byteCount(of: reader.meshURL)
        detail.totalBytes = CaptureStore.byteCount(of: folder)
        if let manifest = try? reader.manifest() {
            detail.manifestFrameCount = manifest.frameCount
        }
        guard let metas = try? reader.anchors() else { return detail }
        detail.anchorCount = metas.count
        for meta in metas {
            guard let anchor = try? reader.anchor(meta) else { continue }
            detail.faceCount += anchor.faceCount
            detail.unlabelledFaceCount += anchor.classes.reduce(0) { $0 + ($1 == MeshClassification.none.rawValue ? 1 : 0) }
        }
        return detail
    }

    private static func fileCount(in folder: URL) -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0 != ".DS_Store" }
            .count
    }
}
