import Foundation
import simd
import XCTest
@testable import LieDAR

/// Fixed, human-checkable payloads shared by the format tests. Every number here is chosen so
/// its on-disk form can be written out by hand in the golden tests.
enum Golden {
    static let anchorID = UUID(uuidString: "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9")!
    static let secondAnchorID = UUID(uuidString: "FFFFFFFF-0000-1111-2222-333333333333")!

    /// 4 × 3 depth, row-major, metres.
    static let depthValues: [Float32] = [0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 4.5, 5.0, 5.5, 6.0]
    /// 4 × 3 confidence.
    static let confidenceValues: [UInt8] = [0, 1, 2, 2, 1, 0, 0, 1, 2, 2, 1, 0]

    static func meta(index: Int) -> FrameMeta {
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4(1.5, 2, -3.25, 1)
        let intrinsics = simd_float3x3(columns: (SIMD3(100, 0, 0), SIMD3(0, 100, 0), SIMD3(64, 48, 1)))
        return FrameMeta(index: index,
                         timestamp: 12.5 + Double(index),
                         cameraTransform: transform,
                         intrinsics: intrinsics,
                         imageResolution: PixelSize(width: 128, height: 96),
                         depthResolution: PixelSize(width: 4, height: 3),
                         trackingState: .normal)
    }

    /// Depth with padded rows (24 bytes per 16-byte row) so the writer must strip padding.
    static func paddedDepth() -> Plane<Float32> {
        var data = Data()
        for row in 0..<3 {
            let rowValues = Array(depthValues[row * 4..<row * 4 + 4])
            data.append(rowValues.withUnsafeBufferPointer { Data(buffer: $0) })
            data.append(Data(repeating: 0xEE, count: 8))
        }
        return Plane(data: data, width: 4, height: 3, bytesPerRow: 24)
    }

    static func confidence() -> Plane<UInt8> {
        Plane(values: confidenceValues, width: 4, height: 3)
    }

    /// Solid BGRA red, 8 × 6.
    static func redBGRA(width: Int = 8, height: Int = 6) throws -> ColorPlanes {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            bytes[i] = 0        // B
            bytes[i + 1] = 0    // G
            bytes[i + 2] = 255  // R
            bytes[i + 3] = 255  // A
        }
        return try ColorPlanes(pixelFormat: .bgra32, width: width, height: height,
                               planes: [Plane(data: Data(bytes), width: width, height: height, bytesPerRow: width * 4)])
    }

    static func frame(index: Int, color: ColorPlanes? = nil) -> FramePayload {
        FramePayload(depth: paddedDepth(), confidence: confidence(), color: color, meta: meta(index: index))
    }

    /// A unit quad at x+10: two triangles, wall then floor. Vertex classes by majority:
    /// v0 tie (wall, floor) → wall; v1 wall; v2 tie → wall; v3 floor.
    static func quadAnchor() -> MeshAnchorPayload {
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4(10, 0, 0, 1)
        return MeshAnchorPayload(id: anchorID, transform: transform,
                                 vertices: [0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0],
                                 faces: [0, 1, 2, 0, 2, 3],
                                 classes: [1, 2])
    }

    /// One ceiling triangle at y+2.5, so the merged PLY's face indices must be offset by 4.
    static func triangleAnchor() -> MeshAnchorPayload {
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4(0, 2.5, 0, 1)
        return MeshAnchorPayload(id: secondAnchorID, transform: transform,
                                 vertices: [0, 0, 0, 2, 0, 0, 0, 0, 2],
                                 faces: [0, 1, 2],
                                 classes: [3])
    }

    static func manifest(frameCount: Int, summary: MeshSnapshotSummary) -> CaptureManifest {
        CaptureManifest(deviceModel: "LieDAR-test",
                        iosVersion: "0",
                        startedAt: Date(timeIntervalSince1970: 1_767_323_045),  // 2026-01-02T03:04:05Z
                        endedAt: Date(timeIntervalSince1970: 1_767_323_105),    // 2026-01-02T03:05:05Z
                        frameCount: frameCount,
                        meshAnchorCount: summary.anchorCount,
                        totalVertices: summary.totalVertices,
                        totalFaces: summary.totalFaces,
                        worldMapSaved: false,
                        notes: "golden",
                        normalTrackingFrameCount: 7,
                        totalTrackingFrameCount: 9)
    }
}

extension XCTestCase {
    /// A fresh directory under the temporary directory, removed in teardown.
    func makeScratchDirectory(_ function: String = #function) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LieDARTests-\(function)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func fileSize(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.intValue ?? -1
    }

    func text(of url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }
}

/// Little-endian bytes of Float32 values, the on-disk form.
func littleEndianBytes(_ values: [Float32]) -> Data {
    var data = Data(capacity: values.count * 4)
    for v in values {
        var bits = v.bitPattern.littleEndian
        data.append(Data(bytes: &bits, count: 4))
    }
    return data
}

func littleEndianBytes(_ values: [UInt32]) -> Data {
    var data = Data(capacity: values.count * 4)
    for v in values {
        var bits = v.littleEndian
        data.append(Data(bytes: &bits, count: 4))
    }
    return data
}
