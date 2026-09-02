import SwiftUI

@main
struct InfinitusMobileApp: App {
    @StateObject private var model = MirrorModel()

    var body: some Scene {
        WindowGroup {
            FleetScreen(model: model)
                // Dark only (#9 phase D2): the Mac popup renders on dark
                // glass in every capture, and the shared views' .primary
                // / .secondary text is picked for that — under a light
                // scheme they go dark on the same dark chrome.
                .preferredColorScheme(.dark)
        }
    }
}
