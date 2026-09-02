import SwiftUI
import InfinitusUI

/// The app shell (#9 native shell): three tabs on a phone, or — for
/// anyone who wants the 1:1 rendering back — the Mac popup itself
/// ("Show as Mac popup", Settings, default off).
///
/// The mirror polling and the intro replay live HERE, not in a screen:
/// both shells read the same model, and only one of them is on screen.
struct RootView: View {
    @ObservedObject var model: MirrorModel
    @StateObject private var usage = MobileUsage()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if model.macPopupView {
                // The Mac popup renders on dark glass in every capture,
                // and the shared views' text is picked for that; the
                // native shell honors the system scheme instead.
                FleetScreen(model: model).preferredColorScheme(.dark)
            } else {
                tabs
            }
        }
        .task {
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)
            }
        }
        // The popup replays its intro when it opens; the phone's
        // equivalent is coming back to the foreground.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, model.snapshotLoaded { model.replayIntro() }
        }
    }

    private var tabs: some View {
        TabView {
            NativeFleetScreen(model: model, usage: usage)
                .tabItem { Label("Fleet", systemImage: "gauge.with.dots.needle.67percent") }
            SessionsScreen(model: model, progress: model.sessionProgress)
                .tabItem { Label("Sessions", systemImage: "brain") }
            NavigationStack {
                SettingsForm(model: model)
                    .navigationTitle("Settings")
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
