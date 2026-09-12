import Foundation
import LieDAR

/// Which synthetic capture the app runs.
///
/// A person tapping through the app gets `.normal`. The journeys pick one with a launch
/// argument (`-LieDARScenario degraded`), which is the only way the tests configure the app:
/// nothing in the app branches on "am I under test", and there is no debug-only code path.
enum Scenario: String, CaseIterable, Identifiable {
    /// A clean room: every face labelled, no loop closure. The default.
    case normal
    /// A source that produces nothing at all. Its streams finish on `start()`, so the capture
    /// must be discarded rather than saved as an empty folder.
    case zeroFrames
    /// The realism defaults: 30 % of faces unlabelled, floor/table confusion, per-anchor label
    /// noise, and a loop-closure event three quarters of the way along the path that moves
    /// every anchor at once.
    case degraded

    var id: String { rawValue }

    /// `-LieDARScenario <rawValue>` on the app's launch arguments.
    static let launchArgument = "-LieDARScenario"
    /// `-LieDARResetStore` empties the capture list before the first screen appears.
    static let resetArgument = "-LieDARResetStore"

    static func fromLaunchArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> Scenario {
        guard let flag = arguments.firstIndex(of: launchArgument), flag + 1 < arguments.count,
              let scenario = Scenario(rawValue: arguments[flag + 1]) else { return .normal }
        return scenario
    }

    static func shouldResetStore(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        arguments.contains(resetArgument)
    }

    var title: String {
        switch self {
        case .normal: return "Clean room"
        case .zeroFrames: return "No frames"
        case .degraded: return "Degraded labels + loop closure"
        }
    }

    /// How long the scripted tour lasts, in seconds of wall clock.
    var seconds: TimeInterval { self == .zeroFrames ? 1 : 6 }

    /// The one place the app configures the package. Everything else in the app talks to the
    /// `CaptureSource` protocol, so swapping in `ARKitCaptureSource` on a device changes this
    /// function and nothing else.
    func makeSource(seed: UInt64 = 7) -> SyntheticCaptureSource {
        var configuration = SyntheticCaptureSource.Configuration(seed: seed, seconds: seconds)
        // Depth and mesh only. The recorder would otherwise JPEG-encode a colour image per frame,
        // which is the slowest thing in the loop and nothing on screen uses it.
        configuration.colorResolution = nil
        switch self {
        case .normal:
            configuration.degradation = .none
            configuration.loopClosure = nil
        case .zeroFrames:
            configuration.zeroFrames = true
        case .degraded:
            break  // Configuration(seed:) already carries 30 % unlabelled and a loop closure.
        }
        return SyntheticCaptureSource(configuration: configuration)
    }
}
