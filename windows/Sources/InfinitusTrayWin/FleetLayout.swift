import Foundation
import InfinitusCore

/// The account panel's CONTENT, decided without touching Win32.
///
/// Why this is a separate file: the Mac gets its row from ~40 lines of
/// SwiftUI (`AccountCells.windowCell`), because SwiftUI does the layout.
/// Win32 has no layout engine — SwiftUI, AppKit and UIKit ship only in
/// Apple's SDKs, and the Windows Swift SDK has none of them (verified
/// 2026-09-04: 25 modules, no SwiftUI) — so every rectangle here is
/// computed by hand. Keeping that arithmetic pure means it can be
/// tested; only the painting needs a device context.
///
/// The NUMBERS and TEXT come from InfinitusCore, never from a second
/// implementation: `GaugeMath` for the remaining/pace/burn figures,
/// `WeeklyRoll.displayPct` for the weekly roll-over, `ResetLabel` for
/// the countdown strings, `AccountVitals` for death. That is what keeps
/// this panel and the Mac popup from disagreeing about the same account.
enum FleetLayout {
    /// One usage window as the panel draws it: a label, a percentage, a
    /// bar fill, and the reset caption under it.
    struct Gauge: Equatable {
        /// "5h", "7d", or a model's short name.
        let label: String
        /// Used percentage, as the engine reports it.
        let usedPct: Double
        /// 0…100 remaining — what the bar actually fills to (HP
        /// semantics: a fresh account shows a full bar).
        let remaining: Double
        /// "3h 34m·Sep 5 00:30", when the engine gave a reset.
        let reset: String?
        /// 0…1 how far ahead of pace (the Mac burns the bar for this).
        let burnHeat: Double
        /// 0…1 how far behind pace.
        let chill: Double
        /// At or past the limit — drawn in the danger colour.
        var spent: Bool { usedPct >= 100 }
    }

    /// One account row.
    struct Row: Equatable {
        let number: Int
        /// Alias, else the email's local part — the Mac's own choice.
        let name: String
        let email: String
        let active: Bool
        /// Held out of auto-rotation (`cswap disable`).
        let disabled: Bool
        /// Every window this account can't work in is spent.
        let dead: Bool
        /// Why it is dead, in the engine's terms ("5h spent").
        let deadNote: String?
        let gauges: [Gauge]
    }

    /// The whole panel.
    struct Panel: Equatable {
        let rows: [Row]
        let activeNumber: Int?
        /// Engine + session summary for the footer.
        let footer: String
        /// Nothing to show, and why — an absent engine is not an error.
        let empty: String?
    }

    /// Build the panel from what the engine reported. `now` is injected
    /// so the countdown strings are testable.
    static func panel(list: AccountList?, live: LiveSessions?,
                      engineInstalled: Bool, now: Date = Date()) -> Panel {
        guard engineInstalled else {
            return Panel(rows: [], activeNumber: nil,
                         footer: footer(live: live, accounts: 0),
                         empty: "No swap engine installed. "
                              + "`uv tool install claude-swap` adds one.")
        }
        guard let list else {
            return Panel(rows: [], activeNumber: nil,
                         footer: footer(live: live, accounts: 0),
                         empty: "Reading accounts\u{2026}")
        }
        guard !list.accounts.isEmpty else {
            return Panel(rows: [], activeNumber: list.activeAccountNumber,
                         footer: footer(live: live, accounts: 0),
                         empty: "No accounts yet \u{2014} `cswap add` registers "
                              + "the one you are logged into.")
        }
        let rows = list.accounts.map { row($0, active: list.activeAccountNumber, now: now) }
        return Panel(rows: rows, activeNumber: list.activeAccountNumber,
                     footer: footer(live: live, accounts: rows.count), empty: nil)
    }

    static func row(_ account: Account, active: Int?, now: Date) -> Row {
        let isActive = account.active || (active != nil && account.number == active)
        // The Mac's display name: alias if set, else the local part of
        // the address (AccountCells.displayName).
        let name: String = {
            if let alias = account.alias, !alias.isEmpty { return alias }
            return String(account.email.prefix(while: { $0 != "@" }))
        }()
        let cause = AccountVitals.cause(account.usage)
        return Row(number: account.number, name: name, email: account.email,
                   active: isActive, disabled: account.disabled ?? false,
                   dead: AccountVitals.isDead(account.usage),
                   deadNote: cause.map { deadNote($0) },
                   gauges: gauges(account.usage, now: now))
    }

    /// "5h spent", "7d spent" — short enough for a row that already
    /// carries two bars.
    static func deadNote(_ cause: AccountVitals.DeadCause) -> String {
        switch cause.kind {
        case .session: return "5h spent"
        case .weekly: return "7d spent"
        case .scoped: return "\(cause.name ?? "model") spent"
        case .credit: return "credit spent"
        }
    }

    /// The 5h and 7d windows, then any per-model windows the engine
    /// reported — the same order the Mac's grid uses.
    static func gauges(_ usage: Usage?, now: Date) -> [Gauge] {
        guard let usage else { return [] }
        var out: [Gauge] = []
        if let five = usage.fiveHour {
            out.append(gauge(five, label: "5h", now: now))
        }
        if let seven = usage.sevenDay {
            // The weekly window rolls: after its reset instant the
            // engine's own pct is stale until the next poll, and
            // WeeklyRoll is what the Mac uses to show 0 instead.
            let pct = WeeklyRoll.displayPct(seven, now: now) ?? seven.pct
            out.append(gauge(seven, label: "7d", overridePct: pct, now: now))
        }
        for scoped in usage.scoped ?? [] {
            out.append(gauge(scoped, label: scoped.name ?? "model", now: now))
        }
        return out
    }

    static func gauge(_ window: UsageWindow, label: String,
                      overridePct: Double? = nil, now: Date) -> Gauge {
        let pct = overridePct ?? window.pct
        return Gauge(
            label: label,
            usedPct: pct,
            remaining: GaugeMath.remaining(usedPct: pct),
            reset: ResetLabel.compact(resetsAt: window.resetsAt,
                                      countdown: window.countdown, now: now),
            burnHeat: GaugeMath.burnHeat(usedPct: pct,
                                         expectedPct: window.expectedPct,
                                         ahead: window.aheadOfPace),
            chill: GaugeMath.chillDepth(usedPct: pct,
                                        expectedPct: window.expectedPct,
                                        ahead: window.aheadOfPace))
    }

    /// "7 sessions · 1 busy · 2 accounts" — the footer line.
    static func footer(live: LiveSessions?, accounts: Int) -> String {
        var parts: [String] = []
        if let live {
            parts.append("\(live.total) session\(live.total == 1 ? "" : "s")")
            if live.busy > 0 { parts.append("\(live.busy) busy") }
            if let waiting = live.waiting, waiting > 0 { parts.append("\(waiting) waiting") }
        }
        if accounts > 0 {
            parts.append("\(accounts) account\(accounts == 1 ? "" : "s")")
        }
        return parts.isEmpty ? "no sessions" : parts.joined(separator: " \u{00B7} ")
    }
}
