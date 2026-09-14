import Combine
import CoreGraphics
import Foundation
import SwiftUI
import simd

/// Draws the room a `SyntheticCaptureSource` is rendering, and keeps drawing it as the pose
/// moves.
///
/// The raycaster runs on the CPU, so the preview asks for a small frame at a modest rate and
/// renders it off the main thread. A pose that has not moved is not redrawn at all, which is
/// what the preview does while a person is reading the screen rather than walking.
@MainActor public final class RoomPreviewModel: ObservableObject {
    /// The latest picture, or `nil` before the first one arrives.
    @Published public private(set) var image: CGImage?
    /// Which of the three colourings to draw.
    @Published public var mode: PreviewMode

    /// Small, because this is a CPU raycast on every frame. A quarter of the LiDAR depth map.
    public static let defaultResolution = PixelSize(width: 128, height: 96)

    public let view: SyntheticCaptureView
    /// Size of the frame the preview renders. Not the size of the frames a capture writes.
    public var resolution: PixelSize
    /// How often the preview looks for a new pose, in hertz.
    public var frameRate: Double

    private var loop: Task<Void, Never>?
    private var drawn: (pose: simd_float4x4, mode: PreviewMode)?

    public init(view: SyntheticCaptureView, mode: PreviewMode = .classification,
                resolution: PixelSize = RoomPreviewModel.defaultResolution, frameRate: Double = 15) {
        self.view = view
        self.mode = mode
        self.resolution = resolution
        self.frameRate = frameRate
    }

    deinit {
        loop?.cancel()
    }

    /// Begins watching the pose. Calling it twice does nothing the second time.
    public func start() {
        guard loop == nil else { return }
        let interval = UInt64(1e9 / max(1, frameRate))
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.drawIfNeeded()
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Renders and publishes one picture, whether or not anything moved.
    public func drawNow() async {
        let capture = view
        let size = resolution
        let mode = self.mode
        let pose = capture.pose
        let drawing = await Task.detached(priority: .userInitiated) { () -> (bytes: [UInt8], width: Int, height: Int) in
            let frame = capture.render(resolution: size)
            return (FramePixels.rgba(frame: frame, mode: mode, classes: capture.classes), frame.width, frame.height)
        }.value
        image = PreviewImage.make(rgba: drawing.bytes, width: drawing.width, height: drawing.height)
        drawn = (pose, mode)
    }

    private func drawIfNeeded() async {
        if let drawn, drawn.pose == view.pose, drawn.mode == mode, image != nil { return }
        await drawNow()
    }
}

/// The picture, and nothing else: no controls, no chrome. Give it a model and put it where the
/// camera feed would be.
public struct RoomPreview: View {
    @ObservedObject public var model: RoomPreviewModel

    public init(model: RoomPreviewModel) {
        self.model = model
    }

    public var body: some View {
        ZStack {
            Color.black
            if let image = model.image {
                Image(decorative: image, scale: 1, orientation: .up)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fill)
            }
        }
        .clipped()
        .task { model.start() }
        .onDisappear { model.stop() }
        .accessibilityLabel(Text("Synthetic room, coloured by \(model.mode.title.lowercased())"))
    }
}

/// What a source puts on screen, whichever source it is. Hand it `source.makeCaptureView()` and
/// it works out what to draw: the room for a synthetic source, the source's own platform view
/// for one that has one, and a line of text for one that has neither.
///
/// This is the view an app writes once, so that swapping the source does not change the screen.
public struct CapturePreview: View {
    private let representable: CaptureViewRepresentable
    private let mode: PreviewMode

    public init(_ representable: CaptureViewRepresentable, mode: PreviewMode = .classification) {
        self.representable = representable
        self.mode = mode
    }

    public var body: some View {
        if let synthetic = representable as? SyntheticCaptureView {
            OwnedRoomPreview(view: synthetic, mode: mode)
        } else {
            PlatformCaptureView(representable)
        }
    }
}

/// A `RoomPreview` that owns its model, for a caller who has no reason to hold one.
struct OwnedRoomPreview: View {
    @StateObject private var model: RoomPreviewModel

    init(view: SyntheticCaptureView, mode: PreviewMode) {
        _model = StateObject(wrappedValue: RoomPreviewModel(view: view, mode: mode))
    }

    var body: some View {
        RoomPreview(model: model)
    }
}

/// A capture view that is a real platform view, wrapped for SwiftUI. The cast is to `UIView`
/// and never to ARKit, so this module still imports no ARKit.
struct PlatformCaptureView: View {
    let representable: CaptureViewRepresentable

    init(_ representable: CaptureViewRepresentable) {
        self.representable = representable
    }

    var body: some View {
        #if os(iOS)
        if let view = representable as? UIView {
            UIViewHost(view: view)
        } else {
            unknownSource
        }
        #else
        unknownSource
        #endif
    }

    private var unknownSource: some View {
        ZStack {
            Color.black
            Text("This capture source has no preview.")
                .font(.footnote)
                .foregroundColor(.white)
                .padding()
        }
    }
}

#if os(iOS)
/// Puts an existing `UIView` on screen without knowing what kind it is.
struct UIViewHost: UIViewRepresentable {
    let view: UIView

    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif
