import Foundation

/// How a rendered frame is coloured for the screen.
public enum PreviewMode: String, Sendable, CaseIterable, Identifiable {
    /// The class of the triangle each ray hit, in the capture format's own colour table.
    case classification
    /// Distance as a grey ramp, near white and far dark.
    case depth
    /// The three bands ARKit reports, as three flat colours.
    case confidence

    public var id: String { rawValue }

    /// A label for a picker.
    public var title: String {
        switch self {
        case .classification: return "Classes"
        case .depth: return "Depth"
        case .confidence: return "Confidence"
        }
    }
}

/// Turns a `Raycaster.Frame` into RGBA8 bytes for the screen.
///
/// This is the half of the preview a test can pin. It is a pure function of the frame, with the
/// same colour table as `tools/preview/main.swift`, so what a person sees in the simulator and
/// what `docs/images/` shows are the same mapping rather than two that drifted apart. A ray that
/// hit nothing is black in every mode.
public enum FramePixels {
    /// Bytes per pixel in the output: red, green, blue, alpha.
    public static let bytesPerPixel = 4

    /// The depth window the grey ramp is spread over, in metres.
    public struct DepthRange: Sendable, Equatable {
        public var near: Float
        public var far: Float

        public init(near: Float, far: Float) {
            self.near = near
            self.far = far
        }

        /// Nearest and furthest hit in `frame`, which is what `tools/preview/main.swift` uses.
        /// A frame that hit nothing spans 0 to 1, so the ramp stays defined.
        public static func spanning(_ frame: Raycaster.Frame) -> DepthRange {
            var near = Float.greatestFiniteMagnitude
            var far = -Float.greatestFiniteMagnitude
            for d in frame.depth where d > 0 {
                near = min(near, d)
                far = max(far, d)
            }
            guard near <= far else { return DepthRange(near: 0, far: 1) }
            return DepthRange(near: near, far: far)
        }
    }

    /// Grey level for one depth sample: 255 at `range.near`, 20 at `range.far`, 0 for a miss.
    /// A range with no width reads as `near`.
    public static func depthGrey(_ depth: Float32, in range: DepthRange) -> UInt8 {
        guard depth > 0 else { return 0 }
        let span = max(range.far - range.near, 1e-6)
        let ramp = min(254, max(0, (depth - range.near) / span * 235))
        return UInt8(255 - ramp)
    }

    /// The colour of one confidence band: 0 low, 1 medium, 2 high. Anything else reads as low,
    /// which is also what a miss reads as.
    public static func confidenceColor(_ band: UInt8) -> (r: UInt8, g: UInt8, b: UInt8) {
        switch band {
        case 2: return (40, 170, 90)
        case 1: return (240, 190, 60)
        default: return (200, 70, 70)
        }
    }

    /// RGBA8 bytes for `frame`, row-major and tightly packed, `frame.width * frame.height * 4`
    /// of them. `classes` is the room's per-triangle classification, indexed by the frame's
    /// triangle ids, and is read only in `.classification`. `depthRange` defaults to the span of
    /// the frame's own hits, which is what the documentation images use; pass one to hold the
    /// ramp still between frames.
    public static func rgba(frame: Raycaster.Frame, mode: PreviewMode,
                            classes: [MeshClassification], depthRange: DepthRange? = nil) -> [UInt8] {
        let count = frame.pixelCount
        var out = [UInt8](repeating: 0, count: count * bytesPerPixel)
        let range = depthRange ?? DepthRange.spanning(frame)
        // Precomputed so the inner loop is a lookup. Eight classes, the same table the format
        // writes into mesh.ply and tools/preview/main.swift draws docs/images with.
        var palette = [(r: UInt8, g: UInt8, b: UInt8)]()
        if mode == .classification {
            for raw in 0...7 { palette.append(CaptureFormat.classificationColor(UInt8(raw))) }
        }
        for i in 0..<count {
            let hit = frame.triangleIDs[i] >= 0
            var rgb: (r: UInt8, g: UInt8, b: UInt8) = (0, 0, 0)
            if hit {
                switch mode {
                case .classification:
                    let id = Int(frame.triangleIDs[i])
                    if id < classes.count { rgb = palette[Int(classes[id].rawValue)] }
                case .depth:
                    let grey = depthGrey(frame.depth[i], in: range)
                    rgb = (grey, grey, grey)
                case .confidence:
                    rgb = confidenceColor(frame.confidence[i])
                }
            }
            let d = i * bytesPerPixel
            out[d] = rgb.r
            out[d + 1] = rgb.g
            out[d + 2] = rgb.b
            out[d + 3] = 255
        }
        return out
    }
}
