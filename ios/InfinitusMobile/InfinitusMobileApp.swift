import SwiftUI

@main
struct InfinitusMobileApp: App {
    @StateObject private var model = MirrorModel()

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
    }
}
