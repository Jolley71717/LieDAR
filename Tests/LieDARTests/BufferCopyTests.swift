import Foundation
import simd
import XCTest
@testable import LieDAR

/// The pointer arithmetic a live source does on buffers it does not own, fed buffers this test
/// builds itself. ARKit is not needed to get row padding, vertex stride or index width wrong,
/// so none of it is needed to prove them right either.
final class BufferCopyTests: XCTestCase {

    /// Runs `body` with a pointer to `bytes`, which stays alive for the call.
    private func withBuffer<T>(_ bytes: [UInt8], _ body: (UnsafeRawPointer) throws -> T) rethrows -> T {
        try bytes.withUnsafeBytes { try body($0.baseAddress!) }
    }

    // MARK: rows and planes

    func testRowsDropThePaddingBetweenRows() throws {
        // Three rows of 2 useful bytes in a buffer whose rows are 5 bytes apart.
        let bytes: [UInt8] = [1, 2, 9, 9, 9,
                              3, 4, 9, 9, 9,
                              5, 6, 9, 9, 9]
        let data = try withBuffer(bytes) { try BufferCopy.rows(from: $0, rowBytes: 2, height: 3, bytesPerRow: 5) }
        XCTAssertEqual(Array(data), [1, 2, 3, 4, 5, 6], "row padding is dropped, not copied")
    }

    func testRowsRefuseARowShorterThanThePixelsItMustHold() {
        let bytes = [UInt8](repeating: 0, count: 32)
        XCTAssertThrowsError(try withBuffer(bytes) { try BufferCopy.rows(from: $0, rowBytes: 8, height: 2, bytesPerRow: 4) }) { error in
            XCTAssertEqual(error as? BufferCopy.LayoutError, .rowTooShort(rowBytes: 8, bytesPerRow: 4),
                           "a row that cannot hold the pixels is a layout error, not a short read")
        }
    }

    func testDepthPlaneIsCopiedOutOfAPaddedFloatBuffer() throws {
        // 3 x 2 Float32 depth with 4 bytes of padding after each row, which is what a
        // CVPixelBuffer of 256 x 192 does at a different scale.
        let values: [Float32] = [0.5, 1.0, 1.5, 2.0, 2.5, 3.0]
        var bytes = [UInt8]()
        for row in 0..<2 {
            bytes += withUnsafeBytes(of: values[row * 3]) { Array($0) }
            bytes += withUnsafeBytes(of: values[row * 3 + 1]) { Array($0) }
            bytes += withUnsafeBytes(of: values[row * 3 + 2]) { Array($0) }
            bytes += [0xFF, 0xFF, 0xFF, 0xFF]
        }
        let plane: Plane<Float32> = try withBuffer(bytes) {
            try BufferCopy.plane(from: $0, width: 3, height: 2, bytesPerRow: 16, as: Float32.self)
        }
        XCTAssertEqual(plane.width, 3)
        XCTAssertEqual(plane.height, 2)
        XCTAssertTrue(plane.isTightlyPacked, "the copy drops the padding, so the plane is packed")
        XCTAssertEqual(plane.values(), values, "depth values survive the copy out of a padded buffer")
        XCTAssertEqual(plane[2, 1], 3.0, "depth pixel (2, 1)")
    }

    func testConfidencePlaneIsCopiedOutOfAPaddedByteBuffer() throws {
        let bytes: [UInt8] = [0, 1, 2, 0xEE, 2, 1, 0, 0xEE]
        let plane: Plane<UInt8> = try withBuffer(bytes) {
            try BufferCopy.plane(from: $0, width: 3, height: 2, bytesPerRow: 4, as: UInt8.self)
        }
        XCTAssertEqual(plane.values(), [0, 1, 2, 2, 1, 0], "confidence values survive the copy")
    }

    func testChromaPlaneCountsPairsAndKeepsTwoBytesPerPair() throws {
        // The interleaved Cb,Cr plane of a 4 x 4 4:2:0 image: 2 pairs per row, 2 rows,
        // 8 bytes of stride with 4 of them padding.
        let bytes: [UInt8] = [10, 20, 30, 40, 0, 0, 0, 0,
                              50, 60, 70, 80, 0, 0, 0, 0]
        let plane = try withBuffer(bytes) {
            try BufferCopy.colorPlane(from: $0, width: 2, height: 2, bytesPerPixel: 2, bytesPerRow: 8)
        }
        XCTAssertEqual(plane.width, 2, "width counts Cb,Cr pairs")
        XCTAssertEqual(plane.bytesPerRow, 4, "a row is two bytes per pair, which is what ColorPlanes validates")
        XCTAssertEqual(Array(plane.data), [10, 20, 30, 40, 50, 60, 70, 80], "both chroma rows, padding dropped")

        // And the plane this produces is one ColorPlanes accepts beside a matching luma plane.
        let luma = try withBuffer([UInt8](repeating: 128, count: 16)) {
            try BufferCopy.colorPlane(from: $0, width: 4, height: 4, bytesPerPixel: 1, bytesPerRow: 4)
        }
        let planes = try ColorPlanes(pixelFormat: .yCbCr420BiPlanarFullRange, width: 4, height: 4, planes: [luma, plane])
        XCTAssertEqual(planes.planes.count, 2, "luma and chroma, in that order")
    }

    // MARK: mesh geometry

    func testVerticesAreReadThroughAStrideWiderThanAVertex() throws {
        // Three vertices of 12 useful bytes each, 16 bytes apart, starting 8 bytes in.
        var bytes = [UInt8](repeating: 0xAA, count: 8)
        for v in 0..<3 {
            for c in 0..<3 {
                bytes += withUnsafeBytes(of: Float(v * 3 + c)) { Array($0) }
            }
            bytes += [0xAA, 0xAA, 0xAA, 0xAA]
        }
        let vertices = try withBuffer(bytes) {
            try BufferCopy.vertices(from: $0, count: 3, stride: 16, offset: 8)
        }
        XCTAssertEqual(vertices, [0, 1, 2, 3, 4, 5, 6, 7, 8],
                       "xyz interleaved, read at the stride and offset the geometry declares")
    }

    func testVerticesRefuseAStrideNarrowerThanAVertex() {
        let bytes = [UInt8](repeating: 0, count: 64)
        XCTAssertThrowsError(try withBuffer(bytes) { try BufferCopy.vertices(from: $0, count: 2, stride: 8, offset: 0) }) { error in
            XCTAssertEqual(error as? BufferCopy.LayoutError, .vertexStride(8),
                           "a stride of 8 cannot hold a three-float vertex")
        }
    }

    func testFaceIndicesAreWidenedFromTwoBytesAndReadStraightFromFour() throws {
        let two: [UInt16] = [0, 1, 2, 2, 1, 3]
        var bytes = [UInt8]()
        for value in two { bytes += withUnsafeBytes(of: value.littleEndian) { Array($0) } }
        let fromTwo = try withBuffer(bytes) {
            try BufferCopy.faceIndices(from: $0, faceCount: 2, indicesPerPrimitive: 3, bytesPerIndex: 2)
        }
        XCTAssertEqual(fromTwo, [0, 1, 2, 2, 1, 3], "two-byte indices widened to UInt32")

        let four: [UInt32] = [7, 8, 9]
        var wide = [UInt8]()
        for value in four { wide += withUnsafeBytes(of: value.littleEndian) { Array($0) } }
        let fromFour = try withBuffer(wide) {
            try BufferCopy.faceIndices(from: $0, faceCount: 1, indicesPerPrimitive: 3, bytesPerIndex: 4)
        }
        XCTAssertEqual(fromFour, [7, 8, 9], "four-byte indices read as they are")
    }

    func testFaceIndicesRefuseALayoutTheyCannotRead() {
        let bytes = [UInt8](repeating: 0, count: 64)
        XCTAssertThrowsError(try withBuffer(bytes) {
            try BufferCopy.faceIndices(from: $0, faceCount: 1, indicesPerPrimitive: 4, bytesPerIndex: 4)
        }) { error in
            XCTAssertEqual(error as? BufferCopy.LayoutError, .indicesPerPrimitive(4), "quads are not triangles")
        }
        XCTAssertThrowsError(try withBuffer(bytes) {
            try BufferCopy.faceIndices(from: $0, faceCount: 1, indicesPerPrimitive: 3, bytesPerIndex: 1)
        }) { error in
            XCTAssertEqual(error as? BufferCopy.LayoutError, .bytesPerIndex(1), "an index width this code does not read")
        }
    }

    func testFaceClassesArePaddedTruncatedAndStridden() {
        let bytes: [UInt8] = [1, 0xFF, 2, 0xFF, 3, 0xFF]

        let padded = withBuffer(bytes) {
            BufferCopy.faceClasses(from: $0, count: 3, stride: 2, offset: 0, faceCount: 5)
        }
        XCTAssertEqual(padded, [1, 2, 3, 0, 0], "a short classification buffer leaves the rest unclassified")

        let truncated = withBuffer(bytes) {
            BufferCopy.faceClasses(from: $0, count: 3, stride: 2, offset: 0, faceCount: 2)
        }
        XCTAssertEqual(truncated, [1, 2], "a long classification buffer is cut to the face count")

        let none = BufferCopy.faceClasses(from: nil, count: 0, stride: 0, offset: 0, faceCount: 3)
        XCTAssertEqual(none, [0, 0, 0], "geometry with no classification is all MeshClassification.none")
    }

    func testCopiedGeometryBuildsAValidMeshAnchorPayload() throws {
        var vertexBytes = [UInt8]()
        for value in [Float](arrayLiteral: 0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 0) {
            vertexBytes += withUnsafeBytes(of: value) { Array($0) }
        }
        var indexBytes = [UInt8]()
        for value in [UInt16](arrayLiteral: 0, 1, 2, 1, 3, 2) {
            indexBytes += withUnsafeBytes(of: value.littleEndian) { Array($0) }
        }
        let vertices = try withBuffer(vertexBytes) { try BufferCopy.vertices(from: $0, count: 4, stride: 12, offset: 0) }
        let faces = try withBuffer(indexBytes) {
            try BufferCopy.faceIndices(from: $0, faceCount: 2, indicesPerPrimitive: 3, bytesPerIndex: 2)
        }
        let classes = withBuffer([UInt8](arrayLiteral: 2)) {
            BufferCopy.faceClasses(from: $0, count: 1, stride: 1, offset: 0, faceCount: 2)
        }
        let payload = MeshAnchorPayload(id: Golden.anchorID, transform: matrix_identity_float4x4,
                                        vertices: vertices, faces: faces, classes: classes)
        try payload.validate()
        XCTAssertEqual(payload.vertexCount, 4, "vertex count")
        XCTAssertEqual(payload.faceCount, 2, "face count")
        XCTAssertEqual(payload.classArray(), [2, 0], "the classified face and the unclassified one")
    }
}
