import SwiftUI

/// The home list. Every capture that has been finished and published, newest first. Each row
/// carries the one number a person wants from it, how big it is on disk.
struct HomeView: View {
    let scenario: Scenario
    @EnvironmentObject private var store: CaptureStore

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                list
            }
            .navigationTitle("Captures")
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .capture:
                    CaptureScreen(scenario: scenario, store: store)
                case .detail(let id):
                    if let capture = store.capture(id: id) {
                        CaptureDetailView(capture: capture)
                    } else {
                        Text("That capture is gone.")
                    }
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Text("\(store.captures.count) saved")
                .font(.title3.monospacedDigit())
                .measuring("home.count", "Saved captures", store.captures.count)
            NavigationLink(value: Route.capture) {
                Text("New capture")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            }
            .accessibilityIdentifier("home.newCapture")
            Text(scenario.title)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .stating("home.scenario", "Scenario", scenario.rawValue)
        }
        .padding()
    }

    @ViewBuilder
    private var list: some View {
        if store.captures.isEmpty {
            Spacer()
            Text("No captures yet.")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("home.empty")
            Spacer()
        } else {
            List {
                ForEach(Array(store.captures.enumerated()), id: \.element.id) { index, capture in
                    NavigationLink(value: Route.detail(capture.id)) {
                        row(capture)
                    }
                    // The row's value is its size in bytes, so a journey asserts the number the
                    // row is actually showing rather than that some row exists.
                    .measuring("capture.row.\(index)", "\(capture.id), bytes on disk", capture.byteCount)
                }
            }
            .listStyle(.plain)
            .accessibilityIdentifier("home.list")
        }
    }

    private func row(_ capture: SavedCapture) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(capture.id).font(.headline)
            Text("\(capture.byteCount) bytes · \(capture.frameCount) frames · \(capture.anchorCount) anchors")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}
