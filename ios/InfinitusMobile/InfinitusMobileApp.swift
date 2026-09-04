import SwiftUI
import UserNotifications
import os

/// Plain alerts from the Mac (issue #3): the Mac's own notifications —
/// switch, resumed sessions, all-exhausted, "waiting on you" — also go
/// to APNs, to whatever phone registered an alert token. This delegate
/// asks for notification permission, registers for remote
/// notifications, and hands the device token to the Mac through the
/// same route the Live Activity tokens use (kind "alert").
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private let log = Logger(subsystem: "com.huuloc.infinitus.mobile", category: "alerts")

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            self.log.notice("notification permission \(granted ? "granted" : "denied")")
            guard granted else { return }
            DispatchQueue.main.async { application.registerForRemoteNotifications() }
        }
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { await LiveActivities.shared.register(kind: .alert, token: deviceToken) }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        log.error("remote notifications unavailable: \(error.localizedDescription)")
    }

    /// Foreground too: an alert about the fleet is worth a banner even
    /// while the fleet screen is open.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

@main
struct InfinitusMobileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
                .onOpenURL { url in
                    // `infinitus://sessions` — a Live Activity tap lands on
                    // whatever is waiting, not the fleet.
                    if url.host == "sessions" { model.requestedTab = "sessions" }
                    else { model.applyPairing(url.absoluteString) }
                }
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
