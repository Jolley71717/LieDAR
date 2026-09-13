import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import LieDAR

/// What the YCbCr to RGB conversion in `JPEGEncoder` actually produces. The only test it had fed
/// uniform grey, where Cb and Cr are both 128 and every coefficient in the matrix is
/// interchangeable: deleting the red channel's chroma term left the whole suite green. 420f is
/// what ARKit hands a real capture source, so this is the path a device capture takes.
final class JPEGColorTests: XCTestCase {

    /// Four quadrant colours, chosen so each one has a distinct Cb and a distinct Cr. Dropping
    /// any single chroma term moves at least one quadrant by more than 100 levels.
    private static let quadrantColors: [(name: String, rgb: (r: UInt8, g: UInt8, b: UInt8))] = [
        ("top left red", (255, 0, 0)),
        ("top right green", (0, 255, 0)),
        ("bottom left blue", (0, 0, 255)),
        ("bottom right yellow", (255, 255, 0)),
    ]

    /// BT.601 full range, forward. Written out here rather than taken from the encoder, so the
    /// test drives the conversion instead of agreeing with it.
    private func yCbCr(_ c: (r: UInt8, g: UInt8, b: UInt8)) -> (y: UInt8, cb: UInt8, cr: UInt8) {
        let r = Double(c.r), g = Double(c.g), b = Double(c.b)
        let y = 0.299 * r + 0.587 * g + 0.114 * b
        let cb = 128 - 0.168736 * r - 0.331264 * g + 0.5 * b
        let cr = 128 + 0.5 * r - 0.418688 * g - 0.081312 * b
        func byte(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }
        return (byte(y), byte(cb), byte(cr))
    }

    /// A 420f image whose four quadrants are `quadrantColors`, both planes filled by hand.
    private func quadrantPlanes(side: Int = 64) throws -> ColorPlanes {
        let half = side / 2
        var luma = [UInt8](repeating: 0, count: side * side)
        var chroma = [UInt8](repeating: 0, count: half * half * 2)
        for y in 0..<side {
            for x in 0..<side {
                let quadrant = (y < half ? 0 : 2) + (x < half ? 0 : 1)
                let c = yCbCr(Self.quadrantColors[quadrant].rgb)
                luma[y * side + x] = c.y
                if y % 2 == 0 && x % 2 == 0 {
                    let ci = (y / 2) * half * 2 + (x / 2) * 2
                    chroma[ci] = c.cb
                    chroma[ci + 1] = c.cr
                }
            }
        }
        return try ColorPlanes(pixelFormat: .yCbCr420BiPlanarFullRange, width: side, height: side,
                               planes: [Plane(data: Data(luma), width: side, height: side, bytesPerRow: side),
                                        Plane(data: Data(chroma), width: half, height: half, bytesPerRow: half * 2)])
    }

    /// Decodes JPEG bytes and returns row-major RGBA, so a named pixel can be read back.
    private func decodeRGBA(_ jpeg: Data) throws -> (pixels: [UInt8], width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw XCTSkip("ImageIO would not decode the JPEG this platform's encoder produced")
        }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw XCTSkip("no sRGB colour space") }
        try pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                throw XCTSkip("could not make a decode context")
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return (pixels, width, height)
    }

    func testFourQuadrantColoursSurviveTheYCbCrConversion() throws {
        let side = 64
        let jpeg = try JPEGEncoder.encode(try quadrantPlanes(side: side), maxLongEdge: side, quality: 1.0)
        let decoded = try decodeRGBA(jpeg)
        XCTAssertEqual(decoded.width, side, "maxLongEdge equals the source side, so nothing is downscaled")
        XCTAssertEqual(decoded.height, side)

        // The centre of each quadrant, well away from the block edges where chroma bleeds.
        let quarter = side / 4
        let centres = [(quarter, quarter), (side - quarter, quarter), (quarter, side - quarter), (side - quarter, side - quarter)]
        // Measured, the round trip at these centres is exact to within one level on this host.
        // The band is left wide for codec differences between macOS and the simulator; it is far
        // below the 30 levels the smallest of the four chroma mutations moves a channel by.
        let band: Double = 16
        for (quadrant, centre) in zip(Self.quadrantColors, centres) {
            let offset = (centre.1 * decoded.width + centre.0) * 4
            let got = (r: decoded.pixels[offset], g: decoded.pixels[offset + 1], b: decoded.pixels[offset + 2])
            XCTAssertEqual(Double(got.r), Double(quadrant.rgb.r), accuracy: band, "\(quadrant.name): R at \(centre)")
            XCTAssertEqual(Double(got.g), Double(quadrant.rgb.g), accuracy: band, "\(quadrant.name): G at \(centre)")
            XCTAssertEqual(Double(got.b), Double(quadrant.rgb.b), accuracy: band, "\(quadrant.name): B at \(centre)")
        }
    }

    /// The same four colours through the BGRA path, so the two branches are held to one standard.
    func testFourQuadrantColoursSurviveTheBGRAPath() throws {
        let side = 64, half = side / 2
        var bgra = [UInt8](repeating: 255, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let c = Self.quadrantColors[(y < half ? 0 : 2) + (x < half ? 0 : 1)].rgb
                let d = (y * side + x) * 4
                bgra[d] = c.b
                bgra[d + 1] = c.g
                bgra[d + 2] = c.r
                bgra[d + 3] = 255
            }
        }
        let planes = try ColorPlanes(pixelFormat: .bgra32, width: side, height: side,
                                    planes: [Plane(data: Data(bgra), width: side, height: side, bytesPerRow: side * 4)])
        let decoded = try decodeRGBA(try JPEGEncoder.encode(planes, maxLongEdge: side, quality: 1.0))
        let quarter = side / 4
        let centres = [(quarter, quarter), (side - quarter, quarter), (quarter, side - quarter), (side - quarter, side - quarter)]
        for (quadrant, centre) in zip(Self.quadrantColors, centres) {
            let offset = (centre.1 * decoded.width + centre.0) * 4
            XCTAssertEqual(Double(decoded.pixels[offset]), Double(quadrant.rgb.r), accuracy: 12, "\(quadrant.name): R")
            XCTAssertEqual(Double(decoded.pixels[offset + 1]), Double(quadrant.rgb.g), accuracy: 12, "\(quadrant.name): G")
            XCTAssertEqual(Double(decoded.pixels[offset + 2]), Double(quadrant.rgb.b), accuracy: 12, "\(quadrant.name): B")
        }
    }
}
