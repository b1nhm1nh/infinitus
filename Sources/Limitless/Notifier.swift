import Foundation
import UserNotifications
import CswapCore

/// User notifications for switch / quota-restored / session-resumed
/// (backlog item 5, v1 scope).
///
/// Two paths: UNUserNotificationCenter when running from a .app bundle that
/// Notification Center actually accepts, else osascript. The UN path can
/// fail at runtime even with a bundle id (ad-hoc signatures are one cause:
/// the auth grant is keyed to the code signature, which changes every
/// rebuild) — so a UN failure downgrades to osascript instead of dropping
/// the notification, and the failure reason is kept for the UI.
enum Notifier {
    /// Last UN-center failure, for surfacing in the popup. Main-thread only.
    nonisolated(unsafe) static var lastAuthError: String?
    private nonisolated(unsafe) static var unUsable = Bundle.main.bundleIdentifier != nil

    /// Call once at app launch (bundled app only): puts the macOS permission
    /// prompt in front of the user immediately instead of at the first
    /// switch — which is exactly when nobody is watching the screen.
    static func requestAuthorization() {
        guard unUsable else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error {
                    unUsable = false
                    DispatchQueue.main.async {
                        lastAuthError = "notifications degraded to osascript: \(error.localizedDescription)"
                    }
                    NSLog("Limitless: UN auth failed, using osascript: \(error)")
                } else if !granted {
                    unUsable = false
                    DispatchQueue.main.async {
                        lastAuthError = "notifications denied in System Settings; using osascript"
                    }
                    NSLog("Limitless: UN auth not granted")
                } else {
                    NSLog("Limitless: UN auth granted — native notifications active")
                }
            }
    }

    static func post(title: String, body: String) {
        if unUsable {
            postBundled(title: title, body: body)
        } else {
            postOsascript(title: title, body: body)
        }
    }

    private static func postBundled(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString,
                                  content: content, trigger: nil)
        ) { error in
            if let error {
                // Delivery refused (unauthorized, unregistered bundle…) —
                // never drop the notification: resend via osascript.
                unUsable = false
                NSLog("Limitless: UN post failed, resending via osascript: \(error)")
                postOsascript(title: title, body: body)
            }
        }
    }

    private static func postOsascript(title: String, body: String) {
        let script = "display notification \"\(AppleScriptEscaping.literal(body))\""
            + " with title \"\(AppleScriptEscaping.literal(title))\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }
}
