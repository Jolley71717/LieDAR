import Foundation
import XCTest
@testable import LieDAR

/// Reads — never copies — a capture written by the format's first consumer and checks this
/// package's reader agrees with it. The folder is private and lives outside the repository;
/// point `LIEDAR_PARITY_CAPTURE` at any capture folder. Skips, with a clear reason, when the
/// variable is unset or the folder is missing (CI has none).
final class LayoutParityTests: XCTestCase {

    /// `LIEDAR_PARITY_CAPTURE` from the environment, and nothing else: no default path, so the
    /// repository bakes in nobody's directory layout. `tools/test.sh` sets it (and forwards it
    /// into the simulator as `TEST_RUNNER_LIEDAR_PARITY_CAPTURE`) only when the folder exists.
    private static var captureFolder: URL? {
        guard let path = ProcessInfo.processInfo.environment["LIEDAR_PARITY_CAPTURE"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func openCapture() throws -> CaptureReader {
        guard let folder = Self.captureFolder else {
            throw XCTSkip("LIEDAR_PARITY_CAPTURE is not set; no consumer capture folder to compare against")
        }
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(CaptureFormat.manifestFile).path) else {
            throw XCTSkip("LIEDAR_PARITY_CAPTURE=\(folder.path) has no \(CaptureFormat.manifestFile)")
        }
        return CaptureReader(folderURL: folder)
    }

    func testManifestParsesAndAgreesWithTheFolder() throws {
        let reader = try openCapture()
        let manifest = try reader.manifest()
        XCTAssertTrue(CaptureFormat.readableFormatVersions.contains(manifest.formatVersion))
        XCTAssertGreaterThan(manifest.frameCount, 0)
        XCTAssertGreaterThan(manifest.meshAnchorCount, 0)
        XCTAssertGreaterThan(manifest.totalVertices, 0)
        XCTAssertGreaterThan(manifest.totalFaces, 0)
        XCTAssertLessThan(manifest.startedAt, manifest.endedAt)

        let contents = reader.contents
        XCTAssertEqual(contents.frameCount, manifest.frameCount, "every accepted frame is complete on disk")
        XCTAssertEqual(contents.meshAnchorCount, manifest.meshAnchorCount)
        XCTAssertEqual(CaptureFormat.disposition(of: contents), .keep)
        XCTAssertEqual(reader.incompleteFrameIndices(), [])
    }

    func testFirstFrameMetaAndBinariesAgree() throws {
        let reader = try openCapture()
        let meta = try reader.frameMeta(0)
        XCTAssertEqual(meta.index, 0)
        XCTAssertEqual(meta.cameraTransform.count, 16)
        XCTAssertEqual(meta.intrinsics.count, 9)
        XCTAssertEqual(meta.state, .normal, "gated writers only write normal-tracking frames")
        XCTAssertEqual(meta.depthResolution, PixelSize(width: 256, height: 192), "LiDAR depth resolution")
        XCTAssertGreaterThan(meta.imageResolution.width, meta.depthResolution.width)
        XCTAssertEqual(meta.intrinsics[8], 1, "homogeneous intrinsics")
        XCTAssertGreaterThan(meta.intrinsics[0], 0, "fx")
        let cx = meta.intrinsics[6], cy = meta.intrinsics[7]
        XCTAssertLessThan(abs(cx - Float(meta.imageResolution.width) / 2), Float(meta.imageResolution.width) / 10, "principal point near centre")
        XCTAssertLessThan(abs(cy - Float(meta.imageResolution.height) / 2), Float(meta.imageResolution.height) / 10)

        let expectedDepthBytes = meta.depthResolution.width * meta.depthResolution.height * 4
        XCTAssertEqual(try fileSize(reader.frameURL(0, extension: CaptureFormat.depthExtension)), expectedDepthBytes)
        XCTAssertEqual(try fileSize(reader.frameURL(0, extension: CaptureFormat.confidenceExtension)), expectedDepthBytes / 4)

        let depth = try reader.depth(0)
        let values = depth.values()
        XCTAssertEqual(values.count, 256 * 192)
        XCTAssertTrue(values.contains { $0 > 0.1 && $0 < 10 }, "depth values are metres in a room")
        let confidence = try XCTUnwrap(try reader.confidence(0))
        XCTAssertTrue(confidence.values().allSatisfy { $0 <= 2 }, "confidence is 0, 1 or 2")
    }

    func testFirstAnchorBinariesMatchTheirMeta() throws {
        let reader = try openCapture()
        let anchors = try reader.anchors()
        XCTAssertGreaterThan(anchors.count, 0)
        let meta = anchors[0]
        XCTAssertEqual(meta.transform.count, 16)
        XCTAssertEqual(meta.verticesFile, "\(meta.identifier).vertices")
        XCTAssertEqual(meta.facesFile, "\(meta.identifier).faces")
        XCTAssertEqual(meta.classesFile, "\(meta.identifier).classes")
        XCTAssertEqual(try fileSize(reader.meshURL.appendingPathComponent(meta.verticesFile)), meta.vertexCount * 12)
        XCTAssertEqual(try fileSize(reader.meshURL.appendingPathComponent(meta.facesFile)), meta.faceCount * 12)
        XCTAssertEqual(try fileSize(reader.meshURL.appendingPathComponent(meta.classesFile)), meta.faceCount, "one class byte per face")

        let anchor = try reader.anchor(meta)
        try anchor.validate()
        XCTAssertTrue(anchor.faceArray().allSatisfy { Int($0.max()) < anchor.vertexCount }, "face indices inside the vertex range")
        XCTAssertTrue(anchor.classArray().allSatisfy { $0 <= 7 })
    }

    func testMergedPLYHeaderIsTheASCIIFormatWeWrite() throws {
        let reader = try openCapture()
        let url = reader.folderURL.appendingPathComponent(CaptureFormat.mergedPLYFile)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = String(decoding: handle.readData(ofLength: 512), as: UTF8.self)
        let lines = head.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "ply")
        XCTAssertEqual(lines[1], "format ascii 1.0")
        XCTAssertTrue(lines.contains("property float x"))
        XCTAssertTrue(lines.contains("property uchar red"))
        XCTAssertTrue(lines.contains("property list uchar int vertex_indices"))
        XCTAssertTrue(lines.contains("end_header"))
        let vertexLine = try XCTUnwrap(lines.first { $0.hasPrefix("element vertex ") })
        XCTAssertEqual(Int(vertexLine.dropFirst("element vertex ".count)), try reader.manifest().totalVertices)
    }
}
