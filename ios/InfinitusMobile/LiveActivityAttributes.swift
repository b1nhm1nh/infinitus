import ActivityKit
import Foundation

// Shared between the app (which starts/updates the activities) and the
// widget extension (which renders them) — compiled into both targets.
// Everything is pre-themed by the app (RowTheme lives in InfinitusCore,
// which the app has at hand with the fleet's prefs): the extension only
// draws strings, colours and percentages.

/// One usage window, themed: "MP" / "HP" / "× Dragon", its colour name,
/// percent used, and the dense reset label ("4h20m·17:49").
struct ActivityWindow: Codable, Hashable {
    var label: String
    var color: String
    var pct: Double
    var reset: String?
}

/// #1: every account is limited; counts down to the first reviver's
/// reset. `Text(timerInterval:)` ticks natively, so the app only sends
/// an update when the reviver or its instant changes.
struct RevivalActivity: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var reviver: String
        var icon: String?
        var revivesAt: Date
        /// Live sessions on the Mac, and how many of them are stopped
        /// waiting for an account (the ones a revival resumes).
        var sessions: Int
        var waiting: Int
        /// The accounts after the reviver, in recovery order: "loc 2:50 PM".
        var later: [String]
        /// Theme words: "revives" / "is dead" … and the flash colour.
        var reviveWord: String
        var deadWord: String
        var accent: String
        /// Final state: the fleet came back.
        var revived: Bool
    }
    var machine: String
}

/// #2: sessions are working — the active account as its themed popup
/// row (icon, slot, level, gold, every window), the session counts, the
/// next candidate as a subtle hint.
struct WorkingActivity: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var active: String
        var icon: String?
        var slot: String
        var plan: String?
        var cash: String?
        var windows: [ActivityWindow]
        /// Index into `windows` of the one closest to its limit.
        var binding: Int?
        var busy: Int
        var total: Int
        var waiting: Int
        var next: String?
        /// Output tokens per minute across the fleet, and 0…1 of the
        /// recent peak for the bar. Nil until something flows.
        var tokensPerMinute: Int?
        var tokenFraction: Double
        var accent: String
        var plain: Bool
    }
    var machine: String
}
