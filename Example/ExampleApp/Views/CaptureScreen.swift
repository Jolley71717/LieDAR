import SwiftUI

/// Start, watch the numbers move, Stop & Save. The HUD shows what the capture loop is doing.
/// Frames written is not the number of samples fed, because the gate rejects most of them.
struct CaptureScreen: View {
    @EnvironmentObject private var store: CaptureStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var engine: CaptureEngine

    private let scenario: Scenario

    /// The store is handed in rather than read from the environment because the engine is a
    /// `@StateObject` built in `init`, and `@EnvironmentObject` is not available that early.
    init(scenario: Scenario, store: CaptureStore) {
        self.scenario = scenario
        _engine = StateObject(wrappedValue: CaptureEngine(scenario: scenario, store: store))
    }

    var body: some View {
        VStack(spacing: 24) {
            hud
            status
            controls
            Spacer()
        }
        .padding()
        .navigationTitle("Capture")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(engine.isRunning)
    }

    private var hud: some View {
        VStack(spacing: 12) {
            readout("Frames", engine.frameCount, "hud.frames")
            readout("Anchors", engine.anchorCount, "hud.anchors")
            readout("Elapsed", String(format: "%.1f", engine.elapsed), "hud.elapsed")
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    private func readout(_ title: String, _ value: some CustomStringConvertible, _ identifier: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(String(describing: value)).font(.title2.monospacedDigit().bold())
        }
        .measuring(identifier, title, value)
    }

    private var status: some View {
        VStack(spacing: 4) {
            Text(engine.phase.rawValue)
                .font(.headline)
                .stating("capture.status", "Status", engine.phase.rawValue)
            Text(engine.message.isEmpty ? scenario.title : engine.message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("capture.message")
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch engine.phase {
        case .idle:
            button("Start", "capture.start") { engine.start() }
        case .running, .finishing:
            button("Stop & Save", "capture.stopAndSave") { Task { await engine.stopAndSave() } }
                .disabled(engine.phase == .finishing)
        case .saved, .discarded, .failed:
            VStack(spacing: 12) {
                if let saved = engine.saved {
                    NavigationLink(value: Route.detail(saved.id)) {
                        Text("Open \(saved.id)").frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                    .accessibilityIdentifier("capture.openSaved")
                }
                button("Done", "capture.done") { dismiss() }
            }
        }
    }

    private func button(_ title: String, _ identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.accentColor.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
        }
        .accessibilityIdentifier(identifier)
    }
}
