import SwiftUI
import InfinitusUI

/// The app shell (#9 native shell): three tabs on a phone — Sessions is
/// home (user 2026-09-04: the phone is opened for what's waiting; the
/// fleet is the detail) — or, for anyone who wants the 1:1 rendering
/// back, the Mac popup itself ("Show as Mac popup", Settings, default
/// off).
///
/// The mirror polling and the intro replay live HERE, not in a screen:
/// both shells read the same model, and only one of them is on screen.
struct RootView: View {
    @ObservedObject var model: MirrorModel
    @StateObject private var usage = MobileUsage()
    /// A launch can name the tab to open on — the same dev seam
    /// `INFINITUS_MIRROR_PATH` is, so a headless simulator capture can
    /// show a screen no one can tap to.
    @State private var tab = ProcessInfo.processInfo
        .environment["INFINITUS_TAB"] ?? "sessions"

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
        // Shake on any screen: capture it, pick a session, sent.
        .background(ShakeToSend(model: model))
        .task {
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)
            }
        }
        // Bars land on their value; no entrance on foreground or on a
        // tab switch (user 2026-09-04: "opening ios app causes all
        // animations to replay weirdly"). Settings › Replay intro still
        // plays it on demand.
        .environment(\.gaugeIntroOnAppear, false)
        .onChange(of: model.requestedTab) { _, requested in
            guard let requested else { return }
            tab = requested
            model.requestedTab = nil
        }
    }

    @ViewBuilder private var tabs: some View {
        // iOS 26: the floating tab bar shrinks to its selected icon as a
        // list scrolls, like Safari's (user 2026-09-04 from the phone:
        // "when scroll up, make the bottom bar collapse like this").
        if #available(iOS 26, *) {
            tabView.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            tabView
        }
    }

    private var tabView: some View {
        TabView(selection: $tab) {
            SessionsScreen(model: model, progress: model.sessionProgress)
                .tabItem { tabLabel("sessions") }
                .tag("sessions")
                .badge(model.liveSessions?.waiting ?? 0)
            NativeFleetScreen(model: model, usage: usage)
                .tabItem { tabLabel("fleet") }
                .tag("fleet")
            NavigationStack {
                SettingsForm(model: model)
                    .navigationTitle(model.rowTheme.tabLabel("settings"))
            }
            .tabItem { tabLabel("settings") }
            .tag("settings")
        }
    }

    /// The theme's tab: "Quests" with a scroll under RPG, plain
    /// Sessions/Fleet/Settings under Off (user 2026-09-04: "themify ios:
    /// bottom bars: icons and names"). "sf:" icons are SF Symbols,
    /// anything else is drawn as text.
    private func tabLabel(_ tab: String) -> some View {
        let theme = model.rowTheme
        let icon = theme.tabIcon(tab)
        return Label {
            Text(theme.tabLabel(tab))
        } icon: {
            if icon.hasPrefix("sf:") { Image(systemName: String(icon.dropFirst(3))) }
            else { Text(icon) }
        }
    }
}
