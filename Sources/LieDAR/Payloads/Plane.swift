import Foundation

/// A single image plane copied out of whatever produced it: raw bytes plus the shape needed to
/// read them. `Element` is the per-pixel scalar (`Float32` for depth, `UInt8` for confidence and
/// for colour planes). Rows may carry padding, so `bytesPerRow` may exceed
/// `width * MemoryLayout<Element>.size`, exactly as a pixel buffer's rows do. `tightlyPacked()`
/// removes it, and that is what goes to disk.
///
/// The type is a plain value with no reference to the buffer it came from, which is the whole
/// point: it can cross task and actor boundaries (RT-3).
public struct Plane<Element: Sendable>: Sendable, Equatable {
    /// `height` rows of `bytesPerRow` bytes each; `data.count == height * bytesPerRow`.
    public var data: Data
    /// Pixels per row.
    public var width: Int
    /// Rows.
    public var height: Int
    /// Bytes from the start of one row to the start of the next, including any padding.
    public var bytesPerRow: Int

    /// Bytes each pixel occupies: `MemoryLayout<Element>.size`.
    public static var bytesPerPixel: Int { MemoryLayout<Element>.size }

    /// Wraps existing bytes. Traps if `data` is shorter than `height * bytesPerRow` or a row
    /// cannot hold `width` pixels. Those are programming errors at the copy site, not runtime
    /// conditions.
    public init(data: Data, width: Int, height: Int, bytesPerRow: Int) {
        precondition(width >= 0 && height >= 0 && bytesPerRow >= 0, "negative plane dimension")
        precondition(width * Self.bytesPerPixel <= bytesPerRow, "row cannot hold \(width) pixels")
        precondition(data.count >= height * bytesPerRow, "plane data shorter than height * bytesPerRow")
        self.data = data
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
    }

    /// A tightly packed plane from row-major values. `values.count` must equal `width * height`.
    public init(values: [Element], width: Int, height: Int) {
        precondition(values.count == width * height, "expected \(width * height) values, got \(values.count)")
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        self.init(data: data, width: width, height: height, bytesPerRow: width * Self.bytesPerPixel)
    }

    /// True when rows carry no padding.
    public var isTightlyPacked: Bool { bytesPerRow == width * Self.bytesPerPixel }

    /// The pixel bytes with row padding removed: `height` rows of `width * bytesPerPixel` bytes,
    /// native (little-endian on every Apple platform) byte order. This is the on-disk layout.
    public func tightlyPacked() -> Data {
        let rowBytes = width * Self.bytesPerPixel
        if isTightlyPacked { return data.count == height * rowBytes ? data : data.prefix(height * rowBytes) }
        var out = Data(count: rowBytes * height)
        out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                guard let dstBase = dst.baseAddress, let srcBase = src.baseAddress else { return }
                for y in 0..<height {
                    dstBase.advanced(by: y * rowBytes).copyMemory(from: srcBase.advanced(by: y * bytesPerRow), byteCount: rowBytes)
                }
            }
        }
        return out
    }

    /// Row-major values, padding removed.
    public func values() -> [Element] {
        let packed = tightlyPacked()
        return packed.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Element.self).prefix(width * height))
        }
    }

    /// The pixel at column `x`, row `y`. Traps when out of range.
    public subscript(x: Int, y: Int) -> Element {
        precondition(x >= 0 && x < width && y >= 0 && y < height, "pixel (\(x), \(y)) outside \(width)×\(height)")
        let offset = y * bytesPerRow + x * Self.bytesPerPixel
        return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Element.self) }
    }
}

/// Width and height in pixels. Mirrors the `imageResolution` / `depthResolution` objects in a
/// frame's JSON.
public struct PixelSize: Codable, Sendable, Equatable, Hashable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}
