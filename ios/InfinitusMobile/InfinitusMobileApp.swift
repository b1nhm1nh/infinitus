import SwiftUI

@main
struct InfinitusMobileApp: App {
    @StateObject private var model = MirrorModel.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Must happen before the app finishes launching.
        BackgroundRefresh.register(model: MirrorModel.shared)
    }

    var body: some Scene {
        WindowGroup {
            // The native shell (#9): tabs by default, the Mac popup on
            // request. RootView owns the polling and the color scheme —
            // only the Mac-popup branch forces dark.
            RootView(model: model)
                // `infinitus://pair?url=…&token=…` — the QR the Mac shows,
                // opened from anywhere on the phone (#9 remote access).
                .onOpenURL { url in model.applyPairing(url.absoluteString) }
        }
        .onChange(of: scenePhase) { _, phase in
            // Leaving: ask for a background refresh so the Live Activities
            // keep moving; coming back: fetch at once instead of waiting
            // for the 10 s loop.
            if phase == .background { BackgroundRefresh.schedule() }
            if phase == .active { Task { await model.refresh() } }
        }
    }
}
