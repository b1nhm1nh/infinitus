import SwiftUI

@main
struct InfinitusMobileApp: App {
    @StateObject private var model = MirrorModel()

    var body: some Scene {
        WindowGroup {
            FleetScreen(model: model)
        }
    }
}
