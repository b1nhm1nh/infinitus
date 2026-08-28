import Foundation
import UserNotifications
import CswapCore

/// User notifications for switch / quota-restored / session-resumed
/// (backlog item 5, v1 scope).
///
/// Two paths: UNUserNotificationCenter when running from a real .app bundle
/// (see make-app.sh), else osascript — a bare `swift run` executable has no
/// bundle identifier and UNUserNotificationCenter aborts without one.
enum Notifier {
    /// Call once at app launch (bundled app only): puts the macOS permission
    /// prompt in front of the user immediately instead of at the first
    /// switch — which is exactly when nobody is watching the screen.
    static func requestAuthorization() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        if Bundle.main.bundleIdentifier != nil {
            postBundled(title: title, body: body)
        } else {
            postOsascript(title: title, body: body)
        }
    }

    private static func postBundled(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        center.add(UNNotificationRequest(identifier: UUID().uuidString,
                                         content: content, trigger: nil))
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
