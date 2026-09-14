import Foundation
import simd
import XCTest
@testable import LieDAR
@testable import LieDARSynthetic
import LieDARUI

/// The frame-to-pixels step is pinned to exact bytes, because it is the one part of the preview
/// a test can see. The values here are the same table `tools/preview/main.swift` writes
/// `docs/images/` with: if a screenshot of the app stops matching the documentation, one of
/// these fails first.
final class PreviewPixelsTests: XCTestCase {
    /// A 2 by 2 frame: a wall hit close and high confidence, a floor hit further out at medium,
    /// a third hit at low confidence, and one ray that hit nothing.
    static func sampleFrame() -> Raycaster.Frame {
        Raycaster.Frame(width: 2, height: 2,
                        depth: [1.0, 3.5, 6.0, 0],
                        confidence: [2, 1, 0, 0],
                        triangleIDs: [0, 1, 2, -1])
    }

    static let sampleClasses: [MeshClassification] = [.wall, .floor, .ceiling]
    static let fixedRange = FramePixels.DepthRange(near: 1, far: 6)

    func pixel(_ rgba: [UInt8], _ index: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        (rgba[index * 4], rgba[index * 4 + 1], rgba[index * 4 + 2], rgba[index * 4 + 3])
    }

    // MARK: Depth

    func testAKnownDepthMapsToAKnownGrey() {
        let range = Self.fixedRange
        XCTAssertEqual(FramePixels.depthGrey(1.0, in: range), 255, "the near end of the range is white")
        XCTAssertEqual(FramePixels.depthGrey(3.5, in: range), 137, "halfway along the range")
        XCTAssertEqual(FramePixels.depthGrey(6.0, in: range), 20, "the far end of the range")
        XCTAssertEqual(FramePixels.depthGrey(0, in: range), 0, "a miss is black")
        XCTAssertEqual(FramePixels.depthGrey(50, in: range), 1, "past the far end is clamped, not wrapped")
    }

    func testDepthModeWritesTheGreyRampAndBlackForAMiss() {
        let rgba = FramePixels.rgba(frame: Self.sampleFrame(), mode: .depth,
                                    classes: Self.sampleClasses, depthRange: Self.fixedRange)
        XCTAssertEqual(rgba.count, 2 * 2 * 4)
        XCTAssertEqual(pixel(rgba, 0).r, 255)
        XCTAssertEqual(pixel(rgba, 0).g, 255)
        XCTAssertEqual(pixel(rgba, 0).b, 255)
        XCTAssertEqual(pixel(rgba, 1).r, 137)
        XCTAssertEqual(pixel(rgba, 2).r, 20)
        XCTAssertEqual(pixel(rgba, 3).r, 0, "the ray that hit nothing is black")
        XCTAssertEqual(pixel(rgba, 3).a, 255, "and still opaque")
    }

    func testTheDefaultDepthRangeSpansTheHitsAndIgnoresMisses() {
        let range = FramePixels.DepthRange.spanning(Self.sampleFrame())
        XCTAssertEqual(range.near, 1.0, accuracy: 1e-6)
        XCTAssertEqual(range.far, 6.0, accuracy: 1e-6)

        let empty = Raycaster.Frame(width: 1, height: 1, depth: [0], confidence: [0], triangleIDs: [-1])
        let fallback = FramePixels.DepthRange.spanning(empty)
        XCTAssertEqual(fallback, FramePixels.DepthRange(near: 0, far: 1), "a frame that hit nothing still has a ramp")
    }

    // MARK: Confidence

    func testAHighConfidencePixelMapsToTheHighColour() {
        XCTAssertTrue(FramePixels.confidenceColor(2) == (40, 170, 90), "high")
        XCTAssertTrue(FramePixels.confidenceColor(1) == (240, 190, 60), "medium")
        XCTAssertTrue(FramePixels.confidenceColor(0) == (200, 70, 70), "low")
    }

    func testConfidenceModeWritesTheThreeBands() {
        let rgba = FramePixels.rgba(frame: Self.sampleFrame(), mode: .confidence, classes: Self.sampleClasses)
        XCTAssertEqual(rgba.count, 2 * 2 * 4)
        XCTAssertTrue(pixel(rgba, 0) == (40, 170, 90, 255), "high confidence")
        XCTAssertTrue(pixel(rgba, 1) == (240, 190, 60, 255), "medium confidence")
        XCTAssertTrue(pixel(rgba, 2) == (200, 70, 70, 255), "low confidence")
        XCTAssertTrue(pixel(rgba, 3) == (0, 0, 0, 255), "a miss is black, not low confidence")
    }

    // MARK: Classification

    func testAWallTriangleMapsToTheWallColour() {
        let rgba = FramePixels.rgba(frame: Self.sampleFrame(), mode: .classification, classes: Self.sampleClasses)
        XCTAssertEqual(rgba.count, 2 * 2 * 4)
        let wall = CaptureFormat.classificationColor(MeshClassification.wall.rawValue)
        XCTAssertTrue(pixel(rgba, 0) == (wall.r, wall.g, wall.b, 255))
        XCTAssertTrue(pixel(rgba, 0) == (230, 138, 46, 255), "the format's wall colour, spelled out")
        let floor = CaptureFormat.classificationColor(MeshClassification.floor.rawValue)
        XCTAssertTrue(pixel(rgba, 1) == (floor.r, floor.g, floor.b, 255))
        XCTAssertTrue(pixel(rgba, 3) == (0, 0, 0, 255), "a miss is black")
    }

    func testClassificationSurvivesATriangleIDWithNoClassEntry() {
        let frame = Raycaster.Frame(width: 1, height: 1, depth: [2], confidence: [2], triangleIDs: [9])
        let rgba = FramePixels.rgba(frame: frame, mode: .classification, classes: [.wall])
        XCTAssertEqual(rgba.count, 4)
        XCTAssertTrue(pixel(rgba, 0) == (0, 0, 0, 255), "an id with no class reads as a miss rather than crashing")
    }

    // MARK: Every mode

    func testEveryModeFillsOnePixelPerSampleAtFullAlpha() {
        let model = RoomModel.parametric(.canonical)
        var pose = matrix_identity_float4x4
        pose.columns.3 = SIMD4(2.5, 1.4, 3.0, 1)
        let size = PixelSize(width: 16, height: 12)
        let frame = Raycaster(model: model).render(cameraToWorld: pose, intrinsics: .iPhonePro, resolution: size)
        XCTAssertGreaterThan(frame.hitCount, 0, "the sample pose sees the room")
        for mode in PreviewMode.allCases {
            let rgba = FramePixels.rgba(frame: frame, mode: mode, classes: model.classes)
            XCTAssertEqual(rgba.count, size.width * size.height * 4, "\(mode.rawValue) writes one RGBA pixel per sample")
            for i in 0..<(size.width * size.height) {
                XCTAssertEqual(rgba[i * 4 + 3], 255, "\(mode.rawValue) pixel \(i) is opaque")
            }
        }
    }
}
