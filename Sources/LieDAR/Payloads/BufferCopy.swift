import Foundation

/// Copies out of a buffer that belongs to someone else.
///
/// A live capture source reads pixel buffers and Metal buffers whose owner is free to recycle
/// them the moment the callback returns, so every payload starts with a copy. The copies
/// themselves are pointer arithmetic over strided rows, which is where the off-by-one lives:
/// row padding, a vertex stride wider than the three floats it carries, two-byte face indices
/// on some devices and four on others, a classification buffer shorter than the face count.
///
/// None of that needs ARKit or CoreVideo to be wrong, so it lives here, in the core module,
/// where a test on a Mac can hand it a buffer it built itself (RT-2). `LieDARARKit` locks the
/// pixel buffer, reads the geometry's layout and calls in here.
///
/// Every entry point takes a raw pointer and the shape of what is behind it. The caller keeps
/// the buffer alive and locked for the duration of the call; none of these functions holds the
/// pointer after returning.
public enum BufferCopy {
    public enum LayoutError: Error, Equatable, Sendable {
        /// `bytesPerRow` cannot hold `width` pixels of `bytesPerPixel`.
        case rowTooShort(rowBytes: Int, bytesPerRow: Int)
        /// A width, height, count or stride was negative.
        case negativeShape(String)
        /// A vertex stride narrower than the three floats a vertex carries.
        case vertexStride(Int)
        /// The geometry is not triangles.
        case indicesPerPrimitive(Int)
        /// An index width this code does not read. ARKit uses 2 or 4.
        case bytesPerIndex(Int)
    }

    /// `height` rows of `rowBytes`, lifted out of a buffer whose rows are `bytesPerRow` apart.
    /// Row padding is dropped, so the result is tightly packed at `rowBytes` per row.
    public static func rows(from base: UnsafeRawPointer, rowBytes: Int, height: Int, bytesPerRow: Int) throws -> Data {
        guard rowBytes >= 0, height >= 0, bytesPerRow >= 0 else {
            throw LayoutError.negativeShape("rowBytes \(rowBytes), height \(height), bytesPerRow \(bytesPerRow)")
        }
        guard rowBytes <= bytesPerRow else { throw LayoutError.rowTooShort(rowBytes: rowBytes, bytesPerRow: bytesPerRow) }
        var out = Data(count: rowBytes * height)
        out.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) in
            guard let start = destination.baseAddress else { return }
            for y in 0..<height {
                start.advanced(by: y * rowBytes)
                    .copyMemory(from: base.advanced(by: y * bytesPerRow), byteCount: rowBytes)
            }
        }
        return out
    }

    /// A tightly packed `Plane` of `Element` copied out of a padded buffer. This is what a depth
    /// map (`Float32`) and a confidence map (`UInt8`) become.
    public static func plane<Element>(from base: UnsafeRawPointer, width: Int, height: Int,
                                      bytesPerRow: Int, as element: Element.Type) throws -> Plane<Element> {
        guard width >= 0 else { throw LayoutError.negativeShape("width \(width)") }
        let rowBytes = width * MemoryLayout<Element>.size
        let data = try rows(from: base, rowBytes: rowBytes, height: height, bytesPerRow: bytesPerRow)
        return Plane<Element>(data: data, width: width, height: height, bytesPerRow: rowBytes)
    }

    /// A `Plane<UInt8>` of a colour image's plane, where a pixel is `bytesPerPixel` wide.
    /// `width` counts pixels of that width, so for the interleaved Cb,Cr plane of a 4:2:0 image
    /// it counts Cb,Cr pairs and `bytesPerPixel` is 2. The result keeps `width * bytesPerPixel`
    /// per row, which is the row length `ColorPlanes` validates against.
    public static func colorPlane(from base: UnsafeRawPointer, width: Int, height: Int,
                                  bytesPerPixel: Int, bytesPerRow: Int) throws -> Plane<UInt8> {
        guard width >= 0, bytesPerPixel > 0 else {
            throw LayoutError.negativeShape("width \(width), bytesPerPixel \(bytesPerPixel)")
        }
        let rowBytes = width * bytesPerPixel
        let data = try rows(from: base, rowBytes: rowBytes, height: height, bytesPerRow: bytesPerRow)
        return Plane<UInt8>(data: data, width: width, height: height, bytesPerRow: rowBytes)
    }

    /// xyz interleaved, read out of a strided vertex buffer of three-component floats.
    /// `stride` is the distance from one vertex to the next and may exceed the 12 bytes a
    /// vertex needs; `offset` is where the first vertex starts.
    public static func vertices(from base: UnsafeRawPointer, count: Int, stride: Int, offset: Int) throws -> [Float] {
        guard count >= 0, offset >= 0 else { throw LayoutError.negativeShape("count \(count), offset \(offset)") }
        let vertexBytes = 3 * MemoryLayout<Float>.size
        guard stride >= vertexBytes else { throw LayoutError.vertexStride(stride) }
        let start = base.advanced(by: offset)
        var out = [Float]()
        out.reserveCapacity(count * 3)
        for i in 0..<count {
            let vertex = start.advanced(by: i * stride)
            out.append(vertex.loadUnaligned(fromByteOffset: 0, as: Float.self))
            out.append(vertex.loadUnaligned(fromByteOffset: 4, as: Float.self))
            out.append(vertex.loadUnaligned(fromByteOffset: 8, as: Float.self))
        }
        return out
    }

    /// Triangle indices widened to `UInt32`. ARKit hands over two-byte indices on some devices
    /// and four-byte on others, and reading one as the other is silent corruption rather than a
    /// crash, so the width is checked here.
    public static func faceIndices(from base: UnsafeRawPointer, faceCount: Int,
                                   indicesPerPrimitive: Int, bytesPerIndex: Int, offset: Int = 0) throws -> [UInt32] {
        guard faceCount >= 0, offset >= 0 else { throw LayoutError.negativeShape("faceCount \(faceCount), offset \(offset)") }
        guard indicesPerPrimitive == 3 else { throw LayoutError.indicesPerPrimitive(indicesPerPrimitive) }
        let start = base.advanced(by: offset)
        let indexCount = faceCount * 3
        var out = [UInt32]()
        out.reserveCapacity(indexCount)
        switch bytesPerIndex {
        case 4:
            for i in 0..<indexCount { out.append(start.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)) }
        case 2:
            for i in 0..<indexCount { out.append(UInt32(start.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self))) }
        default:
            throw LayoutError.bytesPerIndex(bytesPerIndex)
        }
        return out
    }

    /// One classification byte per face. A buffer holding fewer than `faceCount` entries leaves
    /// the rest at 0, which is `MeshClassification.none`, and a longer one is cut short, so the
    /// result always has exactly `faceCount` bytes. Pass `nil` for geometry with no
    /// classification at all.
    public static func faceClasses(from base: UnsafeRawPointer?, count: Int, stride: Int,
                                   offset: Int, faceCount: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: max(0, faceCount))
        guard let base, count > 0, stride > 0, offset >= 0 else { return out }
        let start = base.advanced(by: offset)
        for i in 0..<min(count, out.count) {
            out[i] = start.loadUnaligned(fromByteOffset: i * stride, as: UInt8.self)
        }
        return out
    }
}
