import Foundation

// Display-side logic ported from claude_swap/menubar.py — the JSON feed is
// deliberately raw (resetsAt preserved, pct as stored), so each frontend
// rolls weekly windows against its own clock.

/// Menu-bar title preferences; field names, defaults, and choice sets mirror
/// `MenuBarSettings` in menubar.py (the rumps app persists the same four).
public struct TitlePrefs: Sendable, Equatable {
    public var showAccountName: Bool
    public var titlePct: String   // "off" | "5h" | "7d" | "both"
    public var titleScoped: Bool

    public static let pctChoices = ["off", "5h", "7d", "both"]
    public static let refreshChoices = [30, 60, 300]

    public init(showAccountName: Bool = true, titlePct: String = "both",
                titleScoped: Bool = false) {
        self.showAccountName = showAccountName
        self.titlePct = titlePct
        self.titleScoped = titleScoped
    }
}

public enum WeeklyRoll {
    static let periodSeconds: TimeInterval = 7 * 24 * 3600

    public static func parse(_ iso: String?) -> Date? {
        guard let iso else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: iso) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: iso)
    }

    /// The pct a weekly window should DISPLAY at `now`: 0 once its stored
    /// reset has passed (weekly limits reset on a fixed cadence, so the
    /// stored measurement belongs to a window that no longer exists —
    /// `_rolled_weekly_window` in menubar.py). Missing/future/unparseable
    /// resets return the stored pct unchanged.
    public static func displayPct(_ window: UsageWindow?, now: Date) -> Double? {
        guard let window else { return nil }
        guard let reset = parse(window.resetsAt), reset <= now else { return window.pct }
        return 0.0
    }

    /// The reset instant a rolled weekly window should display: the next
    /// 7-day boundary after `now`. Unrolled windows return their own reset.
    public static func displayReset(_ window: UsageWindow?, now: Date) -> Date? {
        guard let window, let reset = parse(window.resetsAt) else { return nil }
        guard reset <= now else { return reset }
        let missed = floor(now.timeIntervalSince(reset) / periodSeconds) + 1
        return reset.addingTimeInterval(missed * periodSeconds)
    }
}

/// Port of menubar.py `format_title` — segment for segment.
public enum TitleFormatter {
    public static let icon = "⇄"

    public static func format(account: Account?, prefs: TitlePrefs,
                              now: Date = Date()) -> String {
        guard let account else { return icon }
        var segments: [String] = []
        if prefs.showAccountName {
            segments.append(account.alias ?? String(account.email.prefix(while: { $0 != "@" })))
        }
        let usage = account.usage
        if prefs.titlePct == "5h" || prefs.titlePct == "both",
           let pct = usage?.fiveHour?.pct {
            segments.append("\(Int(pct.rounded()))%")
        }
        if prefs.titlePct == "7d" || prefs.titlePct == "both",
           let pct = WeeklyRoll.displayPct(usage?.sevenDay, now: now) {
            segments.append("\(Int(pct.rounded()))%")
        }
        if prefs.titleScoped {
            for window in usage?.scoped ?? [] {
                guard let name = window.name,
                      let pct = WeeklyRoll.displayPct(window, now: now) else { continue }
                segments.append("\(name) \(Int(pct.rounded()))%")
            }
        }
        if segments.isEmpty { return icon }
        return "\(icon) " + segments.joined(separator: " · ")
    }
}

/// Port of menubar.py `parse_switch_history`: "Switched from account X to Y"
/// lines paired with their timestamp trimmed to the minute, most-recent
/// first, unparseable lines skipped.
public enum SwitchHistory {
    public static let limit = 10

    public static func parse(_ logText: String, limit: Int = SwitchHistory.limit) -> [String] {
        let re = #/Switched from account (\d+) to (\d+)/#
        var out: [String] = []
        for line in logText.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let m = line.firstMatch(of: re) else { continue }
            let stamp = String(line.split(separator: " - ", maxSplits: 1)[0]
                .trimmingCharacters(in: .whitespaces).prefix(16))
            out.append("\(m.1) → \(m.2)   \(stamp)")
        }
        return out.suffix(limit).reversed()
    }
}

/// Human notes for non-"ok" `usageStatus` values. Strings are word-for-word
/// `SENTINEL_NOTES` from claude_swap/switcher.py — the codebase's stated
/// invariant is that every surface renders these identically.
public enum SentinelNotes {
    public static let notes: [String: String] = [
        "token_expired": "token expired — refresh deferred this pass; retries automatically",
        "foreign_credential": "live credential belongs to another account — a switch repairs it",
        "api_key": "API key (no quota)",
        "keychain_unavailable": "keychain unavailable — locked or in use; try again",
        "relogin_required": "re-login needed — refresh token dead; log in with Claude Code, then run: cswap add",
        "no_credentials": "no credentials",
    ]

    /// nil for "ok" (rows render their usage windows); otherwise the note,
    /// falling back to the raw status for values this build doesn't know.
    public static func note(for usageStatus: String) -> String? {
        if usageStatus == "ok" { return nil }
        return notes[usageStatus] ?? usageStatus.replacingOccurrences(of: "_", with: " ")
    }
}

/// "2h 15m (11:19)" — countdown plus wall clock, port of oauth.format_reset /
/// reset_clock_string. Recomputed from `resetsAt` at render time (cached feed
/// strings drift as the measurement ages); falls back to the fetch-time
/// strings when the window carries no parseable reset.
public enum ResetLabel {
    public static func label(_ window: UsageWindow?, now: Date = Date(),
                             calendar: Calendar = .current) -> String? {
        guard let window else { return nil }
        guard let reset = WeeklyRoll.parse(window.resetsAt) else {
            guard let clock = window.clock else { return window.countdown }
            return "\(window.countdown ?? "?") (\(clock))"
        }
        let total = max(0, Int(reset.timeIntervalSince(now)))
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        let countdown: String
        if days > 0 { countdown = "\(days)d \(hours)h" }
        else if hours > 0 { countdown = "\(hours)h \(minutes)m" }
        else { countdown = "\(minutes)m" }
        return "\(countdown) (\(clockString(reset, now: now, calendar: calendar)))"
    }

    static func clockString(_ reset: Date, now: Date, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        if calendar.isDate(reset, inSameDayAs: now) {
            f.dateFormat = "HH:mm"
        } else {
            f.dateFormat = "MMM d HH:mm"
        }
        return f.string(from: reset)
    }
}
