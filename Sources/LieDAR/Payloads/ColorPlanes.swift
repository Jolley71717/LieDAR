import Foundation

/// The colour image of a frame, as bytes. Which planes are present is fixed by `pixelFormat`
/// and checked at construction, so a consumer never has to guess from the plane count.
public struct ColorPlanes: Sendable, Equatable {
    /// The two layouts a capture source may hand over. Both are what the camera and a renderer
    /// produce natively; the recorder converts either to JPEG.
    public enum PixelFormat: String, Sendable, Codable, CaseIterable {
        /// Bi-planar Y'CbCr 4:2:0, full range (`kCVPixelFormatType_420YpCbCr8BiPlanarFullRange`,
        /// FourCC `420f`): plane 0 is luma (`width × height`, 1 byte per pixel), plane 1 is
        /// interleaved Cb,Cr (`ceil(width/2) × ceil(height/2)`, 2 bytes per pixel).
        case yCbCr420BiPlanarFullRange = "420f"
        /// One plane of 8-bit B,G,R,A (`kCVPixelFormatType_32BGRA`), 4 bytes per pixel.
        case bgra32 = "BGRA"

        /// Planes this format carries.
        public var planeCount: Int {
            switch self {
            case .yCbCr420BiPlanarFullRange: return 2
            case .bgra32: return 1
            }
        }
    }

    public enum LayoutError: Error, Equatable, Sendable {
        case wrongPlaneCount(expected: Int, got: Int)
        case planeShape(index: Int, expected: PixelSize, got: PixelSize)
        case planeRowTooShort(index: Int, minimumBytesPerRow: Int, got: Int)
    }

    public let pixelFormat: PixelFormat
    /// Full-resolution image size (the luma plane's size for 4:2:0).
    public let width: Int
    public let height: Int
    /// `pixelFormat.planeCount` planes, in the order the format defines. Every plane is `UInt8`
    /// bytes; for 4:2:0 the chroma plane's `width` counts Cb/Cr *pairs* and its rows are
    /// `2 * width` bytes wide at minimum.
    public let planes: [Plane<UInt8>]

    /// Validates the plane count and each plane's shape against `pixelFormat`.
    public init(pixelFormat: PixelFormat, width: Int, height: Int, planes: [Plane<UInt8>]) throws {
        guard planes.count == pixelFormat.planeCount else {
            throw LayoutError.wrongPlaneCount(expected: pixelFormat.planeCount, got: planes.count)
        }
        for (index, plane) in planes.enumerated() {
            let expected = Self.expectedPlaneSize(pixelFormat, index: index, width: width, height: height)
            let got = PixelSize(width: plane.width, height: plane.height)
            guard expected == got else { throw LayoutError.planeShape(index: index, expected: expected, got: got) }
            let minimumRow = Self.bytesPerPixel(pixelFormat, plane: index) * plane.width
            guard plane.bytesPerRow >= minimumRow else {
                throw LayoutError.planeRowTooShort(index: index, minimumBytesPerRow: minimumRow, got: plane.bytesPerRow)
            }
        }
        self.pixelFormat = pixelFormat
        self.width = width
        self.height = height
        self.planes = planes
    }

    /// Pixel size of plane `index` for an image of `width × height`.
    public static func expectedPlaneSize(_ format: PixelFormat, index: Int, width: Int, height: Int) -> PixelSize {
        switch (format, index) {
        case (.yCbCr420BiPlanarFullRange, 1):
            return PixelSize(width: (width + 1) / 2, height: (height + 1) / 2)
        default:
            return PixelSize(width: width, height: height)
        }
    }

    /// Bytes per pixel of plane `index`.
    public static func bytesPerPixel(_ format: PixelFormat, plane index: Int) -> Int {
        switch (format, index) {
        case (.bgra32, _): return 4
        case (.yCbCr420BiPlanarFullRange, 1): return 2
        default: return 1
        }
    }
}
