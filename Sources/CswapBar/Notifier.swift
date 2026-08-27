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
    private static var authRequested = false

    static func post(title: String, body: String) {
        if Bundle.main.bundleIdentifier != nil {
            postBundled(title: title, body: body)
        } else {
            postOsascript(title: title, body: body)
        }
    }

    private static func postBundled(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        if !authRequested {
            authRequested = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
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
