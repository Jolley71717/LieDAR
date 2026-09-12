import Foundation
import ImageIO
import XCTest
@testable import LieDAR

/// Writes a known frame set and mesh through `CaptureRecorder` and asserts every file name,
/// size, byte and JSON field against literal expectations. Values, not presence: a test that
/// only checked the files exist stayed green through a listing bug in the first consumer.
final class FormatGoldenTests: XCTestCase {

    private var folder: URL!
    private var reader: CaptureReader!
    private var summary = MeshSnapshotSummary()

    override func setUp() async throws {
        folder = try makeScratchDirectory()
        let recorder = try CaptureRecorder(folderURL: folder,
                                           options: .init(colorImageMaxLongEdge: 4, colorImageJPEGQuality: 0.9))
        XCTAssertTrue(recorder.write(Golden.frame(index: 0, color: try Golden.redBGRA())))
        XCTAssertTrue(recorder.write(Golden.frame(index: 1)))
        summary = try await recorder.writeMeshSnapshot([Golden.quadAnchor(), Golden.triangleAnchor()])
        try await recorder.finish(manifest: Golden.manifest(frameCount: 2, summary: summary))
        XCTAssertNil(recorder.frameWriteFailure)
        reader = CaptureReader(folderURL: folder)
    }

    // MARK: Layout

    func testDirectoryLayoutIsExactlyTheSpecifiedFiles() throws {
        let top = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(top, ["capture.json", "frames", "mesh", "mesh.ply"])

        let frames = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("frames").path).sorted()
        XCTAssertEqual(frames, ["000000.conf", "000000.depth", "000000.jpg", "000000.json",
                                "000001.conf", "000001.depth", "000001.json"],
                       "frame 1 had no colour, so no .jpg")

        let mesh = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("mesh").path).sorted()
        XCTAssertEqual(mesh, ["0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9.classes",
                              "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9.faces",
                              "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9.vertices",
                              "FFFFFFFF-0000-1111-2222-333333333333.classes",
                              "FFFFFFFF-0000-1111-2222-333333333333.faces",
                              "FFFFFFFF-0000-1111-2222-333333333333.vertices",
                              "anchors.json"])
    }

    func testFrameBaseNamesAreSixDigitZeroPadded() {
        XCTAssertEqual(CaptureFormat.frameBaseName(0), "000000")
        XCTAssertEqual(CaptureFormat.frameBaseName(123), "000123")
        XCTAssertEqual(CaptureFormat.frameBaseName(1_234_567), "1234567")
        XCTAssertEqual(CaptureFormat.frameIndex(fromBaseName: "000123"), 123)
        XCTAssertNil(CaptureFormat.frameIndex(fromBaseName: "123"))
        XCTAssertNil(CaptureFormat.frameIndex(fromBaseName: "anchors"))
    }

    // MARK: Depth and confidence bytes

    func testDepthIsTightlyPackedLittleEndianFloat32() throws {
        let url = folder.appendingPathComponent("frames/000000.depth")
        XCTAssertEqual(try fileSize(url), 48, "4 × 3 × 4 bytes, padding stripped")
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data, littleEndianBytes(Golden.depthValues))
        XCTAssertEqual(Array(data.prefix(4)), [0x00, 0x00, 0x00, 0x3F], "0.5 as little-endian Float32")
        XCTAssertEqual(Array(data.suffix(4)), [0x00, 0x00, 0xC0, 0x40], "6.0 as little-endian Float32")
        XCTAssertFalse(data.contains(0xEE), "the row padding must not reach the disk")
    }

    func testConfidenceIsOneByteperPixel() throws {
        let url = folder.appendingPathComponent("frames/000000.conf")
        XCTAssertEqual(try fileSize(url), 12)
        XCTAssertEqual(Array(try Data(contentsOf: url)), Golden.confidenceValues)
    }

    func testReaderRoundTripsDepthAndConfidence() throws {
        let depth = try reader.depth(1)
        XCTAssertEqual(depth.width, 4)
        XCTAssertEqual(depth.height, 3)
        XCTAssertEqual(depth.bytesPerRow, 16)
        XCTAssertEqual(depth.values(), Golden.depthValues)
        XCTAssertEqual(depth[3, 2], 6.0)
        XCTAssertEqual(try reader.confidence(1)?.values(), Golden.confidenceValues)
    }

    // MARK: Frame meta JSON

    func testFrameMetaJSONIsPrettyPrintedSortedKeysWithExactValues() throws {
        let expected = """
        {
          "cameraTransform" : [
            1,
            0,
            0,
            0,
            0,
            1,
            0,
            0,
            0,
            0,
            1,
            0,
            1.5,
            2,
            -3.25,
            1
          ],
          "depthResolution" : {
            "height" : 3,
            "width" : 4
          },
          "imageResolution" : {
            "height" : 96,
            "width" : 128
          },
          "index" : 1,
          "intrinsics" : [
            100,
            0,
            0,
            0,
            100,
            0,
            64,
            48,
            1
          ],
          "timestamp" : 13.5,
          "trackingState" : "normal"
        }
        """
        XCTAssertEqual(try text(of: folder.appendingPathComponent("frames/000001.json")), expected)

        let meta = try reader.frameMeta(1)
        XCTAssertEqual(meta, Golden.meta(index: 1))
        XCTAssertEqual(meta.state, .normal)
        XCTAssertEqual(meta.cameraMatrix?.translation, SIMD3(1.5, 2, -3.25))
    }

    // MARK: Colour

    func testColourIsAJPEGDownscaledToTheLongEdgeLimit() throws {
        let url = folder.appendingPathComponent("frames/000000.jpg")
        let data = try Data(contentsOf: url)
        XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xD8], "JPEG SOI")
        XCTAssertEqual(Array(data.suffix(2)), [0xFF, 0xD9], "JPEG EOI")

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return XCTFail("ImageIO could not decode the written JPEG")
        }
        XCTAssertEqual(image.width, 4, "8 × 6 scaled to a long edge of 4")
        XCTAssertEqual(image.height, 3)

        // Solid red in, red out (JPEG is lossy, so a band, not an exact byte).
        guard let pixels = image.dataProvider?.data as Data?, let colorSpace = image.colorSpace else {
            return XCTFail("no pixel data")
        }
        XCTAssertEqual(colorSpace.model, .rgb)
        let bytesPerPixel = image.bitsPerPixel / 8
        let alphaFirst = image.alphaInfo == .premultipliedFirst || image.alphaInfo == .first || image.alphaInfo == .noneSkipFirst
        let offset = alphaFirst ? 1 : 0
        let littleEndian = image.bitmapInfo.contains(.byteOrder32Little)
        let (r, g, b): (UInt8, UInt8, UInt8)
        if littleEndian {
            // BGRA / BGRX in memory.
            (r, g, b) = (pixels[2], pixels[1], pixels[0])
        } else {
            (r, g, b) = (pixels[offset], pixels[offset + 1], pixels[offset + 2])
        }
        XCTAssertGreaterThan(r, 200, "red channel of \(bytesPerPixel)-byte pixel")
        XCTAssertLessThan(g, 60)
        XCTAssertLessThan(b, 60)
        XCTAssertEqual(reader.colorJPEG(0), data)
        XCTAssertNil(reader.colorJPEG(1))
    }

    func testEncodedSizeNeverUpscalesAndKeepsAspect() {
        XCTAssertEqual(JPEGEncoder.encodedSize(width: 1920, height: 1440, maxLongEdge: 640), PixelSize(width: 640, height: 480))
        XCTAssertEqual(JPEGEncoder.encodedSize(width: 320, height: 240, maxLongEdge: 640), PixelSize(width: 320, height: 240))
        XCTAssertEqual(JPEGEncoder.encodedSize(width: 960, height: 720, maxLongEdge: 640), PixelSize(width: 640, height: 480))
    }

    func testYCbCr420PlanesEncodeToTheRightSize() throws {
        // 6 × 4 mid-grey: luma 128, chroma neutral.
        let luma = Plane(values: [UInt8](repeating: 128, count: 24), width: 6, height: 4)
        let chroma = Plane<UInt8>(data: Data(repeating: 128, count: 3 * 2 * 2), width: 3, height: 2, bytesPerRow: 6)
        let planes = try ColorPlanes(pixelFormat: .yCbCr420BiPlanarFullRange, width: 6, height: 4, planes: [luma, chroma])
        let jpeg = try JPEGEncoder.encode(planes, maxLongEdge: 640, quality: 0.9)
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return XCTFail("ImageIO could not decode the 420f JPEG")
        }
        XCTAssertEqual(image.width, 6)
        XCTAssertEqual(image.height, 4)
    }

    func testColorPlanesRejectTheWrongPlaneCountOrShape() {
        let luma = Plane(values: [UInt8](repeating: 0, count: 24), width: 6, height: 4)
        XCTAssertThrowsError(try ColorPlanes(pixelFormat: .yCbCr420BiPlanarFullRange, width: 6, height: 4, planes: [luma])) {
            XCTAssertEqual($0 as? ColorPlanes.LayoutError, .wrongPlaneCount(expected: 2, got: 1))
        }
        let badChroma = Plane(values: [UInt8](repeating: 0, count: 24), width: 6, height: 4)
        XCTAssertThrowsError(try ColorPlanes(pixelFormat: .yCbCr420BiPlanarFullRange, width: 6, height: 4, planes: [luma, badChroma])) {
            XCTAssertEqual($0 as? ColorPlanes.LayoutError,
                           .planeShape(index: 1, expected: PixelSize(width: 3, height: 2), got: PixelSize(width: 6, height: 4)))
        }
        XCTAssertThrowsError(try ColorPlanes(pixelFormat: .bgra32, width: 6, height: 4, planes: [luma])) {
            XCTAssertEqual($0 as? ColorPlanes.LayoutError, .planeRowTooShort(index: 0, minimumBytesPerRow: 24, got: 6))
        }
    }

    // MARK: Mesh

    func testAnchorBinariesAreExactBytes() throws {
        let base = folder.appendingPathComponent("mesh/0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9")
        let vertices = try Data(contentsOf: base.appendingPathExtension("vertices"))
        XCTAssertEqual(vertices.count, 48, "4 vertices × 12 bytes")
        XCTAssertEqual(vertices, littleEndianBytes([Float32](arrayLiteral: 0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0)))

        let faces = try Data(contentsOf: base.appendingPathExtension("faces"))
        XCTAssertEqual(faces.count, 24, "2 faces × 12 bytes")
        XCTAssertEqual(faces, littleEndianBytes([UInt32](arrayLiteral: 0, 1, 2, 0, 2, 3)))

        let classes = try Data(contentsOf: base.appendingPathExtension("classes"))
        XCTAssertEqual(Array(classes), [1, 2], "one byte per face: wall, floor")

        XCTAssertEqual(try fileSize(folder.appendingPathComponent("mesh/FFFFFFFF-0000-1111-2222-333333333333.vertices")), 36)
        XCTAssertEqual(try fileSize(folder.appendingPathComponent("mesh/FFFFFFFF-0000-1111-2222-333333333333.faces")), 12)
        XCTAssertEqual(try fileSize(folder.appendingPathComponent("mesh/FFFFFFFF-0000-1111-2222-333333333333.classes")), 1)
    }

    func testAnchorsJSONIsExact() throws {
        let expected = """
        [
          {
            "classesFile" : "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9.classes",
            "faceCount" : 2,
            "facesFile" : "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9.faces",
            "identifier" : "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9",
            "transform" : [
              1,
              0,
              0,
              0,
              0,
              1,
              0,
              0,
              0,
              0,
              1,
              0,
              10,
              0,
              0,
              1
            ],
            "vertexCount" : 4,
            "verticesFile" : "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9.vertices"
          },
          {
            "classesFile" : "FFFFFFFF-0000-1111-2222-333333333333.classes",
            "faceCount" : 1,
            "facesFile" : "FFFFFFFF-0000-1111-2222-333333333333.faces",
            "identifier" : "FFFFFFFF-0000-1111-2222-333333333333",
            "transform" : [
              1,
              0,
              0,
              0,
              0,
              1,
              0,
              0,
              0,
              0,
              1,
              0,
              0,
              2.5,
              0,
              1
            ],
            "vertexCount" : 3,
            "verticesFile" : "FFFFFFFF-0000-1111-2222-333333333333.vertices"
          }
        ]
        """
        XCTAssertEqual(try text(of: folder.appendingPathComponent("mesh/anchors.json")), expected)

        let anchors = try reader.anchors()
        XCTAssertEqual(anchors.count, 2)
        let quad = try reader.anchor(anchors[0])
        XCTAssertEqual(quad, Golden.quadAnchor())
        XCTAssertEqual(quad.vertexArray(), [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0)])
        XCTAssertEqual(quad.faceArray(), [SIMD3(0, 1, 2), SIMD3(0, 2, 3)])
        XCTAssertEqual(quad.classArray(), [1, 2])
    }

    func testMergedPLYIsWorldSpaceASCIIWithMajorityClassColours() throws {
        let expected = """
        ply
        format ascii 1.0
        comment LieDAR raw capture, world space, metres, +Y up
        comment vertex colour = majority mesh classification (see CaptureFormat.classificationColor)
        element vertex 7
        property float x
        property float y
        property float z
        property uchar red
        property uchar green
        property uchar blue
        element face 3
        property list uchar int vertex_indices
        end_header
        10.0 0.0 0.0 230 138 46
        11.0 0.0 0.0 230 138 46
        11.0 1.0 0.0 230 138 46
        10.0 1.0 0.0 46 138 230
        0.0 2.5 0.0 46 200 120
        2.0 2.5 0.0 46 200 120
        0.0 2.5 2.0 46 200 120
        3 0 1 2
        3 0 2 3
        3 4 5 6

        """
        XCTAssertEqual(try text(of: folder.appendingPathComponent("mesh.ply")), expected)
    }

    func testMeshSummaryTotals() {
        XCTAssertEqual(summary, MeshSnapshotSummary(anchorCount: 2, totalVertices: 7, totalFaces: 3))
    }

    func testMeshSnapshotRejectsAnAnchorWhoseBytesDisagreeWithItsCounts() async throws {
        let scratch = try makeScratchDirectory()
        let recorder = try CaptureRecorder(folderURL: scratch)
        var bad = Golden.quadAnchor()
        bad.vertexCount = 5
        do {
            _ = try await recorder.writeMeshSnapshot([bad])
            XCTFail("expected meshLayout")
        } catch let error as CaptureRecorder.RecorderError {
            XCTAssertEqual(error, .meshLayout(anchor: Golden.anchorID, detail: "vertices(expectedBytes: 60, got: 48)"))
        }
        let mesh = try FileManager.default.contentsOfDirectory(atPath: scratch.appendingPathComponent("mesh").path)
        XCTAssertEqual(mesh, [], "nothing is written for a rejected snapshot")
    }

    // MARK: Manifest

    func testManifestJSONIsExact() throws {
        let expected = """
        {
          "deviceModel" : "LieDAR-test",
          "endedAt" : "2026-01-02T03:05:05Z",
          "formatVersion" : 2,
          "frameCount" : 2,
          "iosVersion" : "0",
          "meshAnchorCount" : 2,
          "normalTrackingFrameCount" : 7,
          "notes" : "golden",
          "startedAt" : "2026-01-02T03:04:05Z",
          "totalFaces" : 3,
          "totalTrackingFrameCount" : 9,
          "totalVertices" : 7,
          "worldMapSaved" : false
        }
        """
        XCTAssertEqual(try text(of: folder.appendingPathComponent("capture.json")), expected)

        let manifest = try reader.manifest()
        XCTAssertEqual(manifest, Golden.manifest(frameCount: 2, summary: summary))
        XCTAssertTrue(reader.isFinished)
        XCTAssertEqual(reader.contents, CaptureContents(frameCount: 2, meshAnchorCount: 2))
        XCTAssertEqual(CaptureFormat.disposition(of: reader.contents), .keep)
    }

    func testVersion1ManifestWithoutTrackingCountsDecodes() throws {
        let v1 = """
        {
          "deviceModel" : "synthetic",
          "endedAt" : "2026-01-02T03:05:05Z",
          "formatVersion" : 1,
          "frameCount" : 3,
          "iosVersion" : "0",
          "meshAnchorCount" : 1,
          "notes" : "",
          "startedAt" : "2026-01-02T03:04:05Z",
          "totalFaces" : 1,
          "totalVertices" : 3,
          "worldMapSaved" : true
        }
        """
        let manifest = try CaptureFormat.makeJSONDecoder().decode(CaptureManifest.self, from: Data(v1.utf8))
        XCTAssertEqual(manifest.formatVersion, 1)
        XCTAssertEqual(manifest.frameCount, 3)
        XCTAssertEqual(manifest.normalTrackingFrameCount, 0)
        XCTAssertEqual(manifest.totalTrackingFrameCount, 0)
        XCTAssertTrue(manifest.worldMapSaved)
    }

    func testReaderRejectsAFutureFormatVersion() throws {
        let scratch = try makeScratchDirectory()
        var manifest = Golden.manifest(frameCount: 0, summary: .init())
        manifest.formatVersion = 99
        try CaptureFormat.makeJSONEncoder().encode(manifest).write(to: scratch.appendingPathComponent("capture.json"))
        XCTAssertThrowsError(try CaptureReader(folderURL: scratch).manifest()) {
            XCTAssertEqual($0 as? CaptureReader.ReadError, .unsupportedFormatVersion(99))
        }
    }

    func testClassificationColoursRoundTrip() {
        for cls in MeshClassification.allCases {
            let c = CaptureFormat.classificationColor(cls.rawValue)
            XCTAssertEqual(CaptureFormat.classification(ofColor: c.r, c.g, c.b), cls)
        }
        XCTAssertEqual(CaptureFormat.classification(ofColor: 1, 2, 3), .none)
        let wall = CaptureFormat.classificationColor(1)
        XCTAssertEqual([wall.r, wall.g, wall.b], [230, 138, 46])
        let unknown = CaptureFormat.classificationColor(200)
        XCTAssertEqual([unknown.r, unknown.g, unknown.b], [128, 128, 128])
    }
}
