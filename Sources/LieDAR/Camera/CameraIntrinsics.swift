import Foundation
import simd

/// A pinhole camera for an image of `imageResolution` pixels: `[fx 0 0  0 fy 0  cx cy 1]`
/// column-major, pixel origin top-left, u right, v down, landscape, matching the on-disk `intrinsics`.
public struct CameraIntrinsics: Sendable, Equatable {
    public var fx: Float
    public var fy: Float
    public var cx: Float
    public var cy: Float
    public var imageResolution: PixelSize

    public init(fx: Float, fy: Float, cx: Float, cy: Float, imageResolution: PixelSize) {
        self.fx = fx
        self.fy = fy
        self.cx = cx
        self.cy = cy
        self.imageResolution = imageResolution
    }

    /// The colour camera of an iPhone Pro as ARKit reports it: 1920 × 1440 with a focal length
    /// of about 1340 px (horizontal field of view ≈ 71°) and the principal point near the
    /// centre. Source: `ARCamera.intrinsics` from an iPhone 15 Pro-class device reads
    /// fx = fy ≈ 1343, cx ≈ 964, cy ≈ 727 at 1920 × 1440; the values here are rounded to
    /// clean synthetic constants. They are not copied from any capture. The LiDAR depth map
    /// is 256 × 192 with the same field of view, which is `depth` below.
    public static let iPhonePro = CameraIntrinsics(fx: 1340, fy: 1340, cx: 960, cy: 720,
                                                   imageResolution: PixelSize(width: 1920, height: 1440))

    /// The LiDAR depth map's resolution on every iPhone Pro since the 12 Pro.
    public static let depthResolution = PixelSize(width: 256, height: 192)

    /// The same camera resampled to `resolution` (same field of view).
    public func scaled(to resolution: PixelSize) -> CameraIntrinsics {
        let sx = Float(resolution.width) / Float(imageResolution.width)
        let sy = Float(resolution.height) / Float(imageResolution.height)
        return CameraIntrinsics(fx: fx * sx, fy: fy * sy, cx: cx * sx, cy: cy * sy, imageResolution: resolution)
    }

    /// Column-major 3 × 3, the on-disk form.
    public var matrix: simd_float3x3 {
        simd_float3x3(columns: (SIMD3(fx, 0, 0), SIMD3(0, fy, 0), SIMD3(cx, cy, 1)))
    }
}
