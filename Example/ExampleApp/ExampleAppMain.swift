import SwiftUI

/// A minimal capture app built on LieDAR, and the black box the journeys drive.
///
/// It does the whole round trip: pick a synthetic room, run a scripted capture with a live HUD,
/// save the result to disk in the package's capture format, list it, and read it back. No ARKit,
/// no device, no recorded data.
@main
struct ExampleAppMain: App {
    @StateObject private var store = CaptureStore(reset: Scenario.shouldResetStore())
    private let scenario = Scenario.fromLaunchArguments()

    var body: some Scene {
        WindowGroup {
            HomeView(scenario: scenario)
                .environmentObject(store)
        }
    }
}

/// Where the app can navigate. Push only: there is no modal anywhere in this app, so a journey
/// that ends on Home really is back at rest.
enum Route: Hashable {
    case capture
    case detail(String)
}
