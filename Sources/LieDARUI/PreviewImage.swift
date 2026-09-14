import CoreGraphics
import Foundation

/// RGBA8 bytes to a `CGImage`, which is what SwiftUI can draw on both platforms this package
/// builds for. CoreGraphics only, so nothing here is iOS-only.
enum PreviewImage {
    static let colorSpace = CGColorSpaceCreateDeviceRGB()

    /// A `width` by `height` image from tightly packed RGBA bytes, or `nil` when the byte count
    /// does not match the size.
    static func make(rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, rgba.count == width * height * FramePixels.bytesPerPixel else { return nil }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * FramePixels.bytesPerPixel, space: colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
