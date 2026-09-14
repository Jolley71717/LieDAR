import Foundation
import SwiftUI

/// The controls that walk a person around the room: move, strafe, turn and look, by keyboard
/// where there is one and by buttons everywhere.
///
/// Everything here does one job, which is to say what is held down. The rules live in `Walker`
/// and the pose goes wherever `WalkDriver.onPose` sends it, so this file has nothing in it that
/// a test would want to assert.
///
/// The keyboard is WASD to move, Q and E to turn, R and F to look, and the arrow keys to turn
/// and look. It needs iOS 17 or macOS 14, because that is where `onKeyPress` starts; on an
/// older system the buttons are the only way in, and they do the same thing.
public struct SimulatorControls: View {
    @ObservedObject public var driver: WalkDriver
    /// The colouring the preview is drawing with, or `nil` to leave the picker out.
    private let mode: Binding<PreviewMode>?

    public init(driver: WalkDriver, mode: Binding<PreviewMode>? = nil) {
        self.driver = driver
        self.mode = mode
    }

    public var body: some View {
        VStack(spacing: 12) {
            if let mode {
                Picker("Colour by", selection: mode) {
                    ForEach(PreviewMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            HStack(alignment: .bottom) {
                movePad
                Spacer(minLength: 16)
                lookPad
            }
        }
        .padding(12)
        .background(.black.opacity(0.35))
        .foregroundColor(.white)
        .keyboardWalking(driver)
        .onAppear { driver.start() }
        .onDisappear { driver.stop() }
    }

    // MARK: Pads

    private var movePad: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            GridRow {
                Color.clear.frame(width: Self.buttonSize, height: Self.buttonSize)
                button("Walk forward", "arrow.up", .forward)
                Color.clear.frame(width: Self.buttonSize, height: Self.buttonSize)
            }
            GridRow {
                button("Step left", "arrow.left", .strafeLeft)
                button("Walk back", "arrow.down", .back)
                button("Step right", "arrow.right", .strafeRight)
            }
        }
    }

    private var lookPad: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            GridRow {
                Color.clear.frame(width: Self.buttonSize, height: Self.buttonSize)
                button("Look up", "chevron.up", .lookUp)
                Color.clear.frame(width: Self.buttonSize, height: Self.buttonSize)
            }
            GridRow {
                button("Turn left", "arrow.turn.up.left", .turnLeft)
                button("Look down", "chevron.down", .lookDown)
                button("Turn right", "arrow.turn.up.right", .turnRight)
            }
        }
    }

    static let buttonSize: CGFloat = 44

    /// A button that counts as held for as long as a finger is on it, which a plain `Button`
    /// cannot do: it fires on release.
    private func button(_ label: String, _ symbol: String, _ input: WalkInput) -> some View {
        let down = driver.held.contains(input)
        return Image(systemName: symbol)
            .font(.system(size: 17, weight: .semibold))
            .frame(width: Self.buttonSize, height: Self.buttonSize)
            .background(down ? Color.white.opacity(0.45) : Color.white.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in driver.press(input) }
                .onEnded { _ in driver.release(input) })
            .accessibilityLabel(Text(label))
            .accessibilityAddTraits(down ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: Keyboard

extension View {
    /// Adds key handling where the system has it, and changes nothing where it does not.
    @ViewBuilder func keyboardWalking(_ driver: WalkDriver) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            focusable()
                .focusEffectDisabled()
                .onKeyPress(phases: [.down, .repeat, .up]) { press in
                    guard let input = WalkInput.forPress(press) else { return .ignored }
                    if press.phase == .up {
                        driver.release(input)
                    } else {
                        driver.press(input)
                    }
                    return .handled
                }
        } else {
            self
        }
    }
}

@available(iOS 17.0, macOS 14.0, *)
extension WalkInput {
    /// The control a key press drives: the letter layout, plus the arrow keys for turning and
    /// looking, or `nil` for a key that drives nothing.
    static func forPress(_ press: KeyPress) -> WalkInput? {
        switch press.key {
        case .leftArrow: return .turnLeft
        case .rightArrow: return .turnRight
        case .upArrow: return .lookUp
        case .downArrow: return .lookDown
        default: break
        }
        guard let character = press.characters.first else { return nil }
        return forKey(character)
    }
}

// MARK: The whole surface

/// The room and the controls to walk it, which is the whole simulator surface in one view.
///
/// Put it where the camera feed would be. It takes the camera off the scripted path for as long
/// as it is on screen, and gives it back when it goes away, so a capture recorded while this is
/// up follows the person rather than the script.
public struct SimulatorPreview: View {
    @StateObject private var preview: RoomPreviewModel
    @StateObject private var driver: WalkDriver
    private let source: SyntheticCaptureSource

    public init(source: SyntheticCaptureSource, mode: PreviewMode = .classification,
                resolution: PixelSize = RoomPreviewModel.defaultResolution) {
        self.source = source
        // Both of these are built inside the autoclosure StateObject takes, so they run once
        // for the life of the view rather than on every re-evaluation of the parent's body.
        _preview = StateObject(wrappedValue: RoomPreviewModel(view: Self.view(for: source), mode: mode,
                                                             resolution: resolution))
        _driver = StateObject(wrappedValue: WalkDriver(walker: Self.walker(for: source)))
    }

    static func view(for source: SyntheticCaptureSource) -> SyntheticCaptureView {
        source.makeCaptureView() as? SyntheticCaptureView
            ?? SyntheticCaptureView(raycaster: source.raycaster,
                                    intrinsics: source.configuration.camera.intrinsics) { [source] in source.latestPose }
    }

    static func walker(for source: SyntheticCaptureSource) -> Walker {
        let start = source.configuration.path.sample(at: 0)
        return .looking(from: start.position, at: start.lookAt, bounds: .box(of: source.configuration.room))
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            RoomPreview(model: preview)
            SimulatorControls(driver: driver, mode: $preview.mode)
        }
        .onAppear { driver.drive(source) }
        .onDisappear { source.drivenPose = nil }
    }
}
