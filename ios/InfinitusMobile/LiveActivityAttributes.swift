import ActivityKit
import Foundation

// Shared between the app (which starts/updates the activities) and the
// widget extension (which renders them) — compiled into both targets,
// so nothing here may depend on InfinitusCore.

/// #1: every account is limited; counts down to the first reviver's
/// reset. `Text(timerInterval:)` ticks natively, so the app only sends
/// an update when the reviver or its instant changes.
struct RevivalActivity: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var reviver: String
        var revivesAt: Date
        var sessions: Int
        /// Final state: the fleet came back — "revived — <reviver> is back".
        var revived: Bool
    }
    var machine: String
}

/// #2: sessions are working; the active account and its binding window,
/// the next candidate as a subtle hint.
struct WorkingActivity: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var active: String
        var plan: String?
        var bindingLabel: String
        /// 0…100 of the window closest to its limit.
        var bindingPct: Double
        var busy: Int
        var total: Int
        var next: String?
    }
    var machine: String
}
