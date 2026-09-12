import CoreGraphics
import Foundation
import ImageIO

/// Turns `ColorPlanes` into a JPEG with CoreGraphics and ImageIO only. No UIKit and no CoreImage,
/// so the recorder builds and runs on macOS and in the simulator identically.
enum JPEGEncoder {
    enum EncodeError: Error, Equatable, Sendable {
        case cgImageCreationFailed
        case destinationCreationFailed
        case finalizeFailed
    }

    /// Encodes `planes` as a JPEG, downscaled so the long edge is at most `maxLongEdge` pixels
    /// (never upscaled). `quality` is 0…1 (`kCGImageDestinationLossyCompressionQuality`).
    static func encode(_ planes: ColorPlanes, maxLongEdge: Int, quality: Double) throws -> Data {
        let rgba = try rgbaImage(planes)
        let image = try downscaled(rgba, maxLongEdge: maxLongEdge)
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else {
            throw EncodeError.destinationCreationFailed
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw EncodeError.finalizeFailed }
        return out as Data
    }

    /// Pixel size of the image `encode` produces from a `width × height` source.
    static func encodedSize(width: Int, height: Int, maxLongEdge: Int) -> PixelSize {
        let longEdge = max(width, height)
        guard longEdge > maxLongEdge, longEdge > 0 else { return PixelSize(width: width, height: height) }
        let scale = Double(maxLongEdge) / Double(longEdge)
        return PixelSize(width: max(1, Int((Double(width) * scale).rounded())),
                         height: max(1, Int((Double(height) * scale).rounded())))
    }

    // MARK: Plane → CGImage

    /// A CGImage over an 8-bit RGBA copy of the planes (sRGB, no premultiplication).
    private static func rgbaImage(_ planes: ColorPlanes) throws -> CGImage {
        let width = planes.width, height = planes.height
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        switch planes.pixelFormat {
        case .bgra32:
            let plane = planes.planes[0]
            plane.data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                for y in 0..<height {
                    let row = y * plane.bytesPerRow
                    for x in 0..<width {
                        let s = row + x * 4, d = (y * width + x) * 4
                        rgba[d] = src[s + 2]
                        rgba[d + 1] = src[s + 1]
                        rgba[d + 2] = src[s]
                        rgba[d + 3] = 255
                    }
                }
            }
        case .yCbCr420BiPlanarFullRange:
            let luma = planes.planes[0], chroma = planes.planes[1]
            luma.data.withUnsafeBytes { (ySrc: UnsafeRawBufferPointer) in
                chroma.data.withUnsafeBytes { (cSrc: UnsafeRawBufferPointer) in
                    for y in 0..<height {
                        let yRow = y * luma.bytesPerRow
                        let cRow = (y / 2) * chroma.bytesPerRow
                        for x in 0..<width {
                            let yv = Float(ySrc[yRow + x])
                            let cb = Float(cSrc[cRow + (x / 2) * 2]) - 128
                            let cr = Float(cSrc[cRow + (x / 2) * 2 + 1]) - 128
                            // BT.601 full range.
                            let r = yv + 1.402 * cr
                            let g = yv - 0.344136 * cb - 0.714136 * cr
                            let b = yv + 1.772 * cb
                            let d = (y * width + x) * 4
                            rgba[d] = clamp(r)
                            rgba[d + 1] = clamp(g)
                            rgba[d + 2] = clamp(b)
                            rgba[d + 3] = 255
                        }
                    }
                }
            }
        }
        let data = Data(rgba)
        guard let provider = CGDataProvider(data: data as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: colorSpace,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw EncodeError.cgImageCreationFailed
        }
        return image
    }

    private static func clamp(_ v: Float) -> UInt8 {
        UInt8(max(0, min(255, v.rounded())))
    }

    private static func downscaled(_ image: CGImage, maxLongEdge: Int) throws -> CGImage {
        let target = encodedSize(width: image.width, height: image.height, maxLongEdge: maxLongEdge)
        guard target.width != image.width || target.height != image.height else { return image }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: target.width, height: target.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw EncodeError.cgImageCreationFailed
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: target.width, height: target.height))
        guard let result = context.makeImage() else { throw EncodeError.cgImageCreationFailed }
        return result
    }
}
