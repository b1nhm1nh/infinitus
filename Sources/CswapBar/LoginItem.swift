import SwiftUI
import ServiceManagement

/// "Start at login" via SMAppService.mainApp. Registration binds to the app
/// bundle's CURRENT path (swift/CswapBar/CswapBar.app in this checkout) —
/// rebuilding in place keeps it working, moving the repo silently breaks the
/// login item until the toggle is flipped off and on again.
@MainActor
final class LoginItemModel: ObservableObject {
    @Published var enabled = false
    @Published var note: String?

    func refresh() {
        let status = SMAppService.mainApp.status
        enabled = status == .enabled
        note = status == .requiresApproval
            ? "Waiting for approval — allow Limitless under System Settings → General → Login Items."
            : nil
    }

    func set(_ wanted: Bool) {
        // `swift run CswapBar` has no .app bundle; SMAppService would
        // register the bare executable and the item would never launch.
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            note = "Not running from the app bundle — build it first (make-app.sh), then toggle here."
            enabled = false
            return
        }
        do {
            if wanted {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            note = error.localizedDescription
        }
        refresh()
    }
}
