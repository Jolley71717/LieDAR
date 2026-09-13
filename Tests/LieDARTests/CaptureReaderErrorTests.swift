import Foundation
import simd
import XCTest
@testable import LieDAR

/// Every error `CaptureReader` vends, driven from a folder built to provoke it. A capture folder
/// arrives by AirDrop, iTunes file sharing or an unzip, so its contents are untrusted input: a
/// reader that trapped instead of throwing would take the host app down with it. These tests
/// existed for none of these paths before, which is how a negative dimension, two unchecked
/// multiplications and a symlink that walked out of the folder all survived.
final class CaptureReaderErrorTests: XCTestCase {

    private var folder: URL!
    private var reader: CaptureReader!

    override func setUpWithError() throws {
        folder = try makeScratchDirectory()
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("frames"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("mesh"), withIntermediateDirectories: true)
        reader = CaptureReader(folderURL: folder)
    }

    // MARK: Builders

    /// One anchor meta with a valid 16-float identity transform; every field is overridable so a
    /// test can break exactly one of them.
    private func meta(identifier: String = "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9",
                      transform: [Float] = matrix_identity_float4x4.columnMajorArray,
                      vertexCount: Int = 1,
                      faceCount: Int = 1,
                      verticesFile: String? = nil,
                      facesFile: String? = nil,
                      classesFile: String? = nil) -> MeshAnchorMeta {
        MeshAnchorMeta(identifier: identifier, transform: transform, vertexCount: vertexCount, faceCount: faceCount,
                       verticesFile: verticesFile ?? "\(identifier).vertices",
                       facesFile: facesFile ?? "\(identifier).faces",
                       classesFile: classesFile ?? "\(identifier).classes")
    }

    /// Writes the three binary files an anchor meta names, each the length its counts imply.
    private func writeAnchorBinaries(_ m: MeshAnchorMeta) throws {
        let mesh = folder.appendingPathComponent("mesh")
        try Data(count: m.vertexCount * MeshAnchorPayload.bytesPerVertex).write(to: mesh.appendingPathComponent(m.verticesFile))
        try Data(count: m.faceCount * MeshAnchorPayload.bytesPerFace).write(to: mesh.appendingPathComponent(m.facesFile))
        try Data(count: m.faceCount).write(to: mesh.appendingPathComponent(m.classesFile))
    }

    private func writeAnchorsJSON(_ text: String) throws {
        try Data(text.utf8).write(to: folder.appendingPathComponent("mesh/anchors.json"))
    }

    private func writeFrameMeta(_ m: FrameMeta) throws {
        try CaptureFormat.makeJSONEncoder().encode(m).write(to: folder.appendingPathComponent("frames/000000.json"))
    }

    /// A frame meta whose transform and intrinsics are the right lengths; `depthResolution` and the
    /// two array lengths are what the tests vary.
    private func frameMeta(cameraTransform: [Float] = matrix_identity_float4x4.columnMajorArray,
                           intrinsics: [Float] = [100, 0, 0, 0, 100, 0, 64, 48, 1],
                           depthResolution: PixelSize = PixelSize(width: 4, height: 3)) -> FrameMeta {
        FrameMeta(index: 0, timestamp: 1, cameraTransform: cameraTransform, intrinsics: intrinsics,
                  imageResolution: PixelSize(width: 128, height: 96), depthResolution: depthResolution,
                  trackingState: TrackingState.normal)
    }

    private func readError(_ body: () throws -> Void) -> CaptureReader.ReadError? {
        do {
            try body()
            return nil
        } catch let error as CaptureReader.ReadError {
            return error
        } catch {
            XCTFail("expected a CaptureReader.ReadError, got \(error)")
            return nil
        }
    }

    // MARK: anchors.json itself

    func testAnchorsAreEmptyWhenTheFileIsAbsent() throws {
        XCTAssertEqual(try reader.anchors(), [], "no mesh was captured, which is not an error")
    }

    func testAnchorsJSONThatIsNotJSONThrowsBadAnchors() throws {
        try writeAnchorsJSON("this is not json")
        let error = readError { _ = try reader.anchors() }
        guard case .badAnchors(let detail)? = error else { return XCTFail("expected badAnchors, got \(String(describing: error))") }
        XCTAssertTrue(detail.contains("dataCorrupted") || detail.contains("Corrupt"), "badAnchors carries the decode failure: \(detail)")
    }

    func testAnchorsJSONMissingARequiredFieldThrowsBadAnchors() throws {
        try writeAnchorsJSON("""
        [{ "identifier": "A", "vertexCount": 1, "faceCount": 1 }]
        """)
        let error = readError { _ = try reader.anchors() }
        guard case .badAnchors(let detail)? = error else { return XCTFail("expected badAnchors, got \(String(describing: error))") }
        XCTAssertTrue(detail.contains("transform"), "badAnchors names the missing key: \(detail)")
    }

    // MARK: Names

    func testAnchorFileNameWithAPathSeparatorThrowsUnsafeFileName() throws {
        let m = meta(verticesFile: "../../etc/passwd")
        let error = readError { _ = try reader.anchor(m) }
        XCTAssertEqual(error, .unsafeFileName("../../etc/passwd"))
    }

    func testAnchorFileNameThatIsDotDotThrowsUnsafeFileName() throws {
        let error = readError { _ = try reader.anchor(meta(facesFile: "..")) }
        XCTAssertEqual(error, .unsafeFileName(".."))
    }

    func testAnchorFileNameThatIsEmptyThrowsUnsafeFileName() throws {
        let error = readError { _ = try reader.anchor(meta(classesFile: "")) }
        XCTAssertEqual(error, .unsafeFileName(""))
    }

    func testAnchorFileNameWithABackslashThrowsUnsafeFileName() throws {
        let error = readError { _ = try reader.anchor(meta(verticesFile: "..\\secrets")) }
        XCTAssertEqual(error, .unsafeFileName("..\\secrets"))
    }

    /// The name guard reads the string, and a symlink's name is a legal plain name. Zips and
    /// AirDropped folders carry symlinks, so the reader has to resolve the path as well.
    func testASymlinkPointingOutOfTheFolderThrowsUnsafeFileName() throws {
        let outside = try makeScratchDirectory().appendingPathComponent("outside.bin")
        try Data(repeating: 0xAB, count: 12).write(to: outside)
        let name = "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9.vertices"
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("mesh/\(name)").path,
                                                  withDestinationPath: outside.path)
        let m = meta(vertexCount: 1, faceCount: 1)
        try Data(count: MeshAnchorPayload.bytesPerFace).write(to: folder.appendingPathComponent("mesh/\(m.facesFile)"))
        try Data(count: 1).write(to: folder.appendingPathComponent("mesh/\(m.classesFile)"))
        let error = readError { _ = try reader.anchor(m) }
        XCTAssertEqual(error, .unsafeFileName(name), "a symlink out of mesh/ must not be read")
    }

    /// A symlink is refused even when its target is inside the folder. Nothing that writes a
    /// capture emits one, so allowing it would buy no compatibility, and a link can be re-pointed
    /// after it has been checked where a regular file cannot.
    func testASymlinkPointingInsideTheFolderIsAlsoRefused() throws {
        let m = meta(vertexCount: 1, faceCount: 1)
        try writeAnchorBinaries(m)
        let real = folder.appendingPathComponent("mesh/real.bin")
        try Data(repeating: 0xCD, count: MeshAnchorPayload.bytesPerVertex).write(to: real)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("mesh/\(m.verticesFile)"))
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("mesh/\(m.verticesFile)").path,
                                                  withDestinationPath: real.path)
        XCTAssertEqual(readError { _ = try reader.anchor(m) }, .unsafeFileName(m.verticesFile))
    }

    /// The ordinary case, so the guard cannot pass by refusing everything.
    func testAPlainAnchorStillReadsByteForByte() throws {
        let m = meta(vertexCount: 1, faceCount: 1)
        let bytes = Data([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12])
        try bytes.write(to: folder.appendingPathComponent("mesh/\(m.verticesFile)"))
        try Data(count: MeshAnchorPayload.bytesPerFace).write(to: folder.appendingPathComponent("mesh/\(m.facesFile)"))
        try Data(count: 1).write(to: folder.appendingPathComponent("mesh/\(m.classesFile)"))
        let payload = try reader.anchor(m)
        XCTAssertEqual(payload.vertices, bytes)
        XCTAssertEqual(payload.vertexCount, 1)
        XCTAssertEqual(payload.id.uuidString, m.identifier)
    }

    // MARK: Reads that do not go through an anchor name
    //
    // These paths are built from a constant or a frame index, so their names can never be
    // attacker-controlled. The item at the name still can: a zip carries a symlink at
    // frames/000000.jpg as easily as at mesh/<uuid>.vertices, and colorJPEG hands the bytes it
    // reads straight back to the caller.

    func testASymlinkedColourImageIsNotHandedBack() throws {
        let outside = try makeScratchDirectory().appendingPathComponent("secret.bin")
        try Data("OUTSIDE-SECRET".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("frames/000000.jpg").path,
                                                  withDestinationPath: outside.path)
        XCTAssertNil(reader.colorJPEG(0), "a symlinked colour image reads as absent, not as its target's bytes")
    }

    func testASymlinkedFrameMetaIsNotDecoded() throws {
        let outside = try makeScratchDirectory().appendingPathComponent("outside.json")
        try CaptureFormat.makeJSONEncoder().encode(frameMeta()).write(to: outside)
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("frames/000000.json").path,
                                                  withDestinationPath: outside.path)
        XCTAssertEqual(readError { _ = try reader.frameMeta(0) }, .frameIncomplete(0))
    }

    func testASymlinkedManifestIsNotDecoded() throws {
        // A manifest that would decode perfectly well, so the only thing stopping it is the link.
        let outside = try makeScratchDirectory().appendingPathComponent("outside.json")
        try CaptureFormat.makeJSONEncoder()
            .encode(CaptureManifest(deviceModel: "elsewhere", iosVersion: "0",
                                    startedAt: Date(timeIntervalSince1970: 0), endedAt: Date(timeIntervalSince1970: 1),
                                    frameCount: 1, meshAnchorCount: 1, totalVertices: 3, totalFaces: 1))
            .write(to: outside)
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("capture.json").path,
                                                  withDestinationPath: outside.path)
        guard case .missingManifest? = readError({ _ = try reader.manifest() }) else {
            return XCTFail("a symlinked manifest must not be decoded")
        }
    }

    func testASymlinkedAnchorsFileIsNotDecoded() throws {
        // One real anchor outside, so a reader that follows the link comes back with an entry.
        let outside = try makeScratchDirectory().appendingPathComponent("outside.json")
        try CaptureFormat.makeJSONEncoder().encode([meta()]).write(to: outside)
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("mesh/anchors.json").path,
                                                  withDestinationPath: outside.path)
        XCTAssertEqual(try reader.anchors(), [], "a symlinked anchors.json reads as absent, not as its target's entries")
    }

    func testASymlinkedDepthFileIsRefused() throws {
        try writeFrameMeta(frameMeta())
        let outside = try makeScratchDirectory().appendingPathComponent("outside.bin")
        try Data(count: 48).write(to: outside)
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("frames/000000.depth").path,
                                                  withDestinationPath: outside.path)
        XCTAssertEqual(readError { _ = try reader.depth(0) }, .unsafeFileName("000000.depth"))
    }

    func testADirectoryWhereAnAnchorFileShouldBeThrowsUnsafeFileName() throws {
        let m = meta(vertexCount: 1, faceCount: 1)
        try writeAnchorBinaries(m)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("mesh/\(m.verticesFile)"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("mesh/\(m.verticesFile)"),
                                               withIntermediateDirectories: false)
        let error = readError { _ = try reader.anchor(m) }
        XCTAssertEqual(error, .unsafeFileName(m.verticesFile), "only a regular file may be read as anchor bytes")
    }

    // MARK: Counts

    func testNegativeVertexCountThrowsBadCount() throws {
        let error = readError { _ = try reader.anchor(meta(vertexCount: -1)) }
        XCTAssertEqual(error, .badCount("0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9"))
    }

    func testNegativeFaceCountThrowsBadCount() throws {
        let error = readError { _ = try reader.anchor(meta(faceCount: -1)) }
        XCTAssertEqual(error, .badCount("0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9"))
    }

    /// `vertexCount * 12` overflowed and trapped. Int.max is what a hand-edited anchors.json
    /// carries most easily, and 4611686018427387904 is the smallest count that overflows a
    /// multiply by 12 without being obviously silly.
    func testVertexCountThatOverflowsTheByteCountThrowsBadCount() throws {
        for count in [Int.max, 4_611_686_018_427_387_904] {
            let error = readError { _ = try reader.anchor(meta(vertexCount: count)) }
            XCTAssertEqual(error, .badCount("0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9"), "vertexCount \(count)")
        }
    }

    func testFaceCountThatOverflowsTheByteCountThrowsBadCount() throws {
        let error = readError { _ = try reader.anchor(meta(faceCount: Int.max)) }
        XCTAssertEqual(error, .badCount("0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9"))
    }

    /// A count that is merely absurd does not overflow anything, so it stays a plain short file.
    /// This is the line between the two verdicts and it must not move.
    func testAnAbsurdButNonOverflowingCountStaysAShortFile() throws {
        let m = meta(vertexCount: 10_000_000_000, faceCount: 1)
        try Data(count: 12).write(to: folder.appendingPathComponent("mesh/\(m.verticesFile)"))
        let error = readError { _ = try reader.anchor(m) }
        XCTAssertEqual(error, .shortFile(m.verticesFile, expected: 120_000_000_000, got: 12))
    }

    // MARK: Transform and identifier

    func testAnchorTransformWithFifteenFloatsThrowsBadAnchors() throws {
        let error = readError { _ = try reader.anchor(meta(transform: Array(repeating: 0, count: 15))) }
        guard case .badAnchors(let detail)? = error else { return XCTFail("expected badAnchors, got \(String(describing: error))") }
        XCTAssertTrue(detail.contains("15 values, not 16"), "badAnchors says what was wrong: \(detail)")
    }

    /// The reader used to fall back to a fresh `UUID()` for an identifier it could not parse, so
    /// two reads of one folder produced two different anchor ids and anything keyed on anchor
    /// identity silently lost track. A deterministic read must not invent identity.
    func testAnIdentifierThatIsNotAUUIDThrowsRatherThanMintingANewOne() throws {
        let m = meta(identifier: "not-a-uuid", vertexCount: 1, faceCount: 1)
        try writeAnchorBinaries(m)
        let error = readError { _ = try reader.anchor(m) }
        guard case .badAnchors(let detail)? = error else { return XCTFail("expected badAnchors, got \(String(describing: error))") }
        XCTAssertTrue(detail.contains("not-a-uuid"), "badAnchors names the identifier: \(detail)")
    }

    // MARK: Missing and short files

    func testAnchorFileThatIsAbsentThrowsMissingFile() throws {
        let m = meta(vertexCount: 1, faceCount: 1)
        let error = readError { _ = try reader.anchor(m) }
        XCTAssertEqual(error, .missingFile(m.verticesFile))
    }

    func testAnchorFileShorterThanItsCountThrowsShortFileWithBothCounts() throws {
        let m = meta(vertexCount: 4, faceCount: 1)
        try Data(count: 20).write(to: folder.appendingPathComponent("mesh/\(m.verticesFile)"))
        let error = readError { _ = try reader.anchor(m) }
        XCTAssertEqual(error, .shortFile(m.verticesFile, expected: 48, got: 20), "4 vertices are 48 bytes, the file has 20")
    }

    func testShortClassesFileIsReportedAgainstTheFaceCount() throws {
        let m = meta(vertexCount: 1, faceCount: 3)
        try Data(count: MeshAnchorPayload.bytesPerVertex).write(to: folder.appendingPathComponent("mesh/\(m.verticesFile)"))
        try Data(count: 3 * MeshAnchorPayload.bytesPerFace).write(to: folder.appendingPathComponent("mesh/\(m.facesFile)"))
        try Data(count: 2).write(to: folder.appendingPathComponent("mesh/\(m.classesFile)"))
        let error = readError { _ = try reader.anchor(m) }
        XCTAssertEqual(error, .shortFile(m.classesFile, expected: 3, got: 2))
    }

    // MARK: Frame meta

    func testFrameWithNoJSONThrowsFrameIncomplete() throws {
        XCTAssertEqual(readError { _ = try reader.frameMeta(0) }, .frameIncomplete(0))
        XCTAssertEqual(readError { _ = try reader.depth(0) }, .frameIncomplete(0))
    }

    func testFrameMetaThatIsNotJSONThrowsBadFrameMeta() throws {
        try Data("{".utf8).write(to: folder.appendingPathComponent("frames/000000.json"))
        let error = readError { _ = try reader.frameMeta(0) }
        guard case .badFrameMeta(let index, let detail)? = error else { return XCTFail("expected badFrameMeta, got \(String(describing: error))") }
        XCTAssertEqual(index, 0)
        XCTAssertTrue(detail.contains("dataCorrupted") || detail.contains("Corrupt"), "badFrameMeta carries the decode failure: \(detail)")
    }

    func testFrameMetaWithAShortCameraTransformThrowsBadFrameMeta() throws {
        try writeFrameMeta(frameMeta(cameraTransform: Array(repeating: 0, count: 12)))
        XCTAssertEqual(readError { _ = try reader.frameMeta(0) },
                       .badFrameMeta(0, "cameraTransform has 12 values, not 16"))
    }

    func testFrameMetaWithTheWrongIntrinsicsLengthThrowsBadFrameMeta() throws {
        try writeFrameMeta(frameMeta(intrinsics: Array(repeating: 0, count: 6)))
        XCTAssertEqual(readError { _ = try reader.frameMeta(0) },
                       .badFrameMeta(0, "intrinsics has 6 values, not 9"))
    }

    /// A width of −4 made the byte count −64, the `data.count >= bytes` guard passed, and
    /// `data.prefix(-64)` trapped. Every other malformed field threw; this one killed the process.
    func testNegativeDepthResolutionThrowsBadFrameMeta() throws {
        try writeFrameMeta(frameMeta(depthResolution: PixelSize(width: -4, height: 3)))
        try Data(count: 48).write(to: folder.appendingPathComponent("frames/000000.depth"))
        // depth() first: that is the call that trapped, and it has to throw before it can be
        // compared with anything.
        let fromDepth = readError { _ = try reader.depth(0) }
        guard case .badFrameMeta(let index, let detail)? = fromDepth else {
            return XCTFail("expected badFrameMeta, got \(String(describing: fromDepth))")
        }
        XCTAssertEqual(index, 0)
        XCTAssertTrue(detail.contains("-4"), "badFrameMeta names the bad size: \(detail)")
        XCTAssertEqual(readError { _ = try reader.frameMeta(0) }, fromDepth, "frameMeta() reports the same thing")
        XCTAssertEqual(readError { _ = try reader.confidence(0) }, fromDepth, "confidence() reports the same thing")
    }

    func testZeroDepthResolutionThrowsBadFrameMeta() throws {
        try writeFrameMeta(frameMeta(depthResolution: PixelSize(width: 4, height: 0)))
        let error = readError { _ = try reader.frameMeta(0) }
        guard case .badFrameMeta? = error else { return XCTFail("expected badFrameMeta, got \(String(describing: error))") }
    }

    /// `width * height * 4` overflowed and trapped.
    func testDepthResolutionThatOverflowsTheByteCountThrowsBadFrameMeta() throws {
        for size in [PixelSize(width: 4_611_686_018_427_387_904, height: 1),
                     PixelSize(width: Int.max, height: Int.max)] {
            try writeFrameMeta(frameMeta(depthResolution: size))
            let error = readError { _ = try reader.frameMeta(0) }
            guard case .badFrameMeta? = error else {
                return XCTFail("expected badFrameMeta for \(size), got \(String(describing: error))")
            }
        }
    }

    func testDepthFileAbsentThrowsMissingFile() throws {
        try writeFrameMeta(frameMeta())
        XCTAssertEqual(readError { _ = try reader.depth(0) }, .missingFile("000000.depth"))
    }

    func testShortDepthFileThrowsShortFileWithBothCounts() throws {
        try writeFrameMeta(frameMeta())
        try Data(count: 40).write(to: folder.appendingPathComponent("frames/000000.depth"))
        XCTAssertEqual(readError { _ = try reader.depth(0) }, .shortFile("000000.depth", expected: 48, got: 40))
    }

    // MARK: Manifest

    func testManifestAbsentThrowsMissingManifest() throws {
        let error = readError { _ = try reader.manifest() }
        guard case .missingManifest(let path)? = error else { return XCTFail("expected missingManifest, got \(String(describing: error))") }
        XCTAssertTrue(path.hasSuffix("capture.json"), "missingManifest names the path it looked at: \(path)")
    }
}
