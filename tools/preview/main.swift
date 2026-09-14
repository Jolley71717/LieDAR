// Renders one frame from the synthetic source three ways and writes PNGs, so the readme can
// show what the fake sensor actually produces instead of describing it.
//
// Built and run by tools/make_preview.sh. Not part of the package's products: it exists to
// regenerate docs/images/, and committing the PNGs is what the readme reads.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import simd
import LieDARSynthetic

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs/images")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let spec = RoomSpec.canonical
let room = RoomModel.parametric(spec)
let caster = Raycaster(model: room)

// Stand in the room at chest height, looking along it, the pose a walk-through would pass through.
let eye = SIMD3<Float>(1.6, CameraPath.chestHeight, 1.2)
let target = SIMD3<Float>(spec.width * 0.5, CameraPath.chestHeight - 0.1, spec.depth)
let forward = simd_normalize(target - eye)
let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), forward))
let up = simd_cross(forward, right)
var pose = matrix_identity_float4x4
pose.columns.0 = SIMD4(right, 0)
pose.columns.1 = SIMD4(up, 0)
pose.columns.2 = SIMD4(-forward, 0)
pose.columns.3 = SIMD4(eye, 1)

let frame = caster.render(cameraToWorld: pose, intrinsics: .iPhonePro)
let w = frame.width, h = frame.height

func writePNG(_ rgba: [UInt8], _ name: String) throws {
    let cs = CGColorSpaceCreateDeviceRGB()
    var bytes = rgba
    let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let image = ctx.makeImage()!
    let url = outDir.appendingPathComponent(name)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "png", code: 1) }
    print("  wrote \(url.lastPathComponent)")
}

// Depth: near is white, far is dark, a miss is black.
let hits = frame.depth.filter { $0 > 0 }
let near = hits.min() ?? 0, far = hits.max() ?? 1
var depthRGBA = [UInt8](repeating: 255, count: w * h * 4)
for i in 0..<(w * h) {
    let d = frame.depth[i]
    let v: UInt8 = d > 0 ? UInt8(255 - min(254, max(0, (d - near) / (far - near) * 235))) : 0
    depthRGBA[i * 4] = v; depthRGBA[i * 4 + 1] = v; depthRGBA[i * 4 + 2] = v
}
try writePNG(depthRGBA, "depth.png")

// Confidence: the three bands ARKit reports, as three flat colours.
var confRGBA = [UInt8](repeating: 255, count: w * h * 4)
for i in 0..<(w * h) {
    let c: (UInt8, UInt8, UInt8)
    switch frame.confidence[i] {
    case 2: c = (40, 170, 90)     // high
    case 1: c = (240, 190, 60)    // medium
    default: c = (200, 70, 70)    // low, or a miss
    }
    confRGBA[i * 4] = c.0; confRGBA[i * 4 + 1] = c.1; confRGBA[i * 4 + 2] = c.2
}
try writePNG(confRGBA, "confidence.png")

// Classification: the per-face class each triangle carries, in the format's own colour table.
var classRGBA = [UInt8](repeating: 255, count: w * h * 4)
for i in 0..<(w * h) {
    let id = frame.triangleIDs[i]
    if id < 0 { classRGBA[i * 4] = 0; classRGBA[i * 4 + 1] = 0; classRGBA[i * 4 + 2] = 0; continue }
    let cls = room.classes[Int(id)]
    let rgb = CaptureFormat.classificationColor(cls.rawValue)
    classRGBA[i * 4] = rgb.r; classRGBA[i * 4 + 1] = rgb.g; classRGBA[i * 4 + 2] = rgb.b
}
try writePNG(classRGBA, "classes.png")

print("  \(w) by \(h), \(frame.hitCount) of \(w * h) rays hit, depth \(String(format: "%.2f", near)) to \(String(format: "%.2f", far)) m")
