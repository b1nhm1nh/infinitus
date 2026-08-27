import Foundation

/// User notifications for switch / quota-restored / session-resumed
/// (backlog item 5, v1 scope).
///
/// Via osascript, not UNUserNotificationCenter: a bare SwiftPM executable
/// has no bundle identifier, and UNUserNotificationCenter aborts without
/// one. Swap this for the real framework when M5 packages a proper .app.
enum Notifier {
    static func post(title: String, body: String) {
        let escape = { (s: String) in s.replacingOccurrences(of: "\"", with: "\\\"") }
        let script = "display notification \"\(escape(body))\" with title \"\(escape(title))\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }
}
