import ActivityKit
import Foundation
import InfinitusCore
import InfinitusUI
import os

/// Drives the two Live Activities (#1 all-dead countdown, #2 working
/// sessions) from each mirror refresh. No push pipeline: the app
/// updates while it runs, the countdown ticks natively on the lock
/// screen (`Text(timerInterval:)`), and `staleDate` lets iOS grey out a
/// working activity the app hasn't refreshed for a while. Pushed
/// updates (APNs from the Mac) are the follow-up if the budget wants it.
/// Content is themed here (user 2026-09-03 "use the theme for the live
/// activities, enrich it with the other info") the same way the popup
/// row is: RowTheme labels, glyphs, colour names, dense reset labels.
@MainActor
final class LiveActivities {
    static let shared = LiveActivities()

    private let log = Logger(subsystem: "com.huuloc.infinitus.mobile", category: "live-activity")
    private var revival: Activity<RevivalActivity>?
    private var working: Activity<WorkingActivity>?
    /// How long a working activity stays fresh without the app refreshing.
    private static let workingStale: TimeInterval = 15 * 60

    private init() {
        // Adopt activities that survived an app relaunch.
        revival = Activity<RevivalActivity>.activities.first
        working = Activity<WorkingActivity>.activities.first
    }

    func sync(fleet: MirrorFleetModel?, machine: String, tokenRate: TokenRate?) {
        guard let fleet else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            log.notice("live activities disabled for this app")
            return
        }
        syncRevival(fleet: fleet, machine: machine)
        syncWorking(fleet: fleet, machine: machine, tokenRate: tokenRate)
    }

    // MARK: #1

    private func syncRevival(fleet: MirrorFleetModel, machine: String) {
        let theme = fleet.rowTheme
        let allDead = fleet.nextCandidate == nil
        if allDead, let rec = fleet.nextRecovery, let at = WeeklyRoll.parse(rec.at), at > Date() {
            let account = fleet.accounts.first { $0.number == rec.number }
            let state = RevivalActivity.ContentState(
                reviver: account.map(Self.name(of:)) ?? "#\(rec.number)",
                icon: account?.icon.map(PopupGlyph.text),
                revivesAt: at,
                sessions: fleet.liveSessions?.total ?? 0,
                waiting: fleet.liveSessions?.waiting ?? 0,
                later: Self.laterRevivals(fleet, after: rec.number, theme: theme),
                reviveWord: theme.plain ? "recovers" : PopupGlyph.text(theme.revivePrefix),
                deadWord: theme.plain ? "limited" : theme.deadVerb,
                accent: theme.flashColor,
                revived: false)
            let content = ActivityContent(state: state, staleDate: at.addingTimeInterval(60))
            if let revival, revival.activityState == .active {
                if revival.content.state != state { Task { await revival.update(content) } }
            } else {
                do {
                    revival = try Activity.request(attributes: RevivalActivity(machine: machine),
                                                   content: content)
                    log.notice("revival activity started: \(state.reviver) at \(at)")
                } catch {
                    log.error("revival activity refused: \(error.localizedDescription)")
                }
            }
        } else if let revival, revival.activityState == .active {
            // Back from the dead: a brief "revived" card, then gone.
            var final = revival.content.state
            final.revived = true
            self.revival = nil
            Task {
                await revival.end(ActivityContent(state: final, staleDate: nil),
                                  dismissalPolicy: .after(Date().addingTimeInterval(120)))
            }
        }
    }

    // MARK: #2

    private func syncWorking(fleet: MirrorFleetModel, machine: String, tokenRate: TokenRate?) {
        let busy = fleet.liveSessions?.busy ?? 0
        if busy > 0, let active = fleet.accounts.first(where: { $0.active }) {
            let theme = fleet.rowTheme
            let windows = Self.windows(active, theme: theme)
            let state = WorkingActivity.ContentState(
                active: Self.name(of: active),
                icon: (active.icon ?? (theme.plain ? nil : theme.activeIcon)).map(PopupGlyph.text),
                slot: theme.plain ? "#\(active.number)" : PopupGlyph.text(theme.slotPrefix) + "\(active.number)",
                plan: active.plan.map { theme.plain ? $0 : theme.planLabel($0, compact: true) },
                cash: Self.cash(active, report: fleet.report, theme: theme),
                windows: windows,
                binding: windows.indices.max { windows[$0].pct < windows[$1].pct },
                busy: busy,
                total: fleet.liveSessions?.total ?? busy,
                waiting: fleet.liveSessions?.waiting ?? 0,
                next: fleet.nextCandidate.flatMap { number in
                    fleet.accounts.first { $0.number == number }.map { next in
                        (theme.plain ? "→ " : PopupGlyph.text(theme.nextIcon) + " ") + Self.name(of: next)
                    }
                },
                tokensPerMinute: tokenRate.flatMap { $0.perMinute > 0 ? $0.perMinute : nil },
                tokenFraction: tokenRate?.fraction ?? 0,
                accent: theme.flashColor,
                plain: theme.plain)
            let content = ActivityContent(state: state,
                                          staleDate: Date().addingTimeInterval(Self.workingStale))
            if let working, working.activityState == .active {
                // Budget discipline: only a real change goes out.
                if Self.differs(working.content.state, state) { Task { await working.update(content) } }
            } else {
                do {
                    working = try Activity.request(attributes: WorkingActivity(machine: machine),
                                                   content: content)
                    log.notice("working activity started: \(state.active) \(state.busy)/\(state.total)")
                } catch {
                    log.error("working activity refused: \(error.localizedDescription)")
                }
            }
        } else if let working, working.activityState == .active {
            self.working = nil
            Task { await working.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// Switch, ≥5-point move of any window, a reset label that rolled,
    /// or session counts — everything else waits for the next refresh.
    private static func differs(_ a: WorkingActivity.ContentState, _ b: WorkingActivity.ContentState) -> Bool {
        var stable = a
        stable.windows = b.windows
        stable.tokensPerMinute = b.tokensPerMinute
        stable.tokenFraction = b.tokenFraction
        if stable != b { return true }
        // Tokens/minute: a fifth of the bar or the number appearing/vanishing.
        if (a.tokensPerMinute == nil) != (b.tokensPerMinute == nil)
            || abs(a.tokenFraction - b.tokenFraction) >= 0.2 { return true }
        guard a.windows.count == b.windows.count else { return true }
        return zip(a.windows, b.windows).contains { x, y in
            x.label != y.label || x.reset != y.reset || abs(x.pct - y.pct) >= 5
        }
    }

    /// The other dead accounts' recovery times after the first reviver,
    /// soonest first — "loc 2:50 PM · P2 Sep 4".
    private static func laterRevivals(_ fleet: MirrorFleetModel, after number: Int,
                                      theme: RowTheme, now: Date = Date()) -> [String] {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let rows: [(Date, String)] = fleet.accounts.compactMap { account in
            guard account.number != number, let usage = account.usage else { return nil }
            let resets = [usage.fiveHour, usage.sevenDay].compactMap { $0 }
                .filter { $0.pct >= 100 }
                .compactMap { WeeklyRoll.parse($0.resetsAt) }
            guard let at = resets.max(), at > now else { return nil }
            let clock = Calendar.current.isDate(at, inSameDayAs: now)
                ? formatter.string(from: at)
                : at.formatted(.dateTime.month(.abbreviated).day())
            return (at, "\(name(of: account)) \(clock)")
        }
        return rows.sorted { $0.0 < $1.0 }.prefix(3).map(\.1)
    }

    private static func name(of account: Account) -> String {
        account.alias ?? String(account.email.prefix(while: { $0 != "@" }))
    }

    /// "💰1,871" — the popup's cash cell, same estimate, same caveat.
    private static func cash(_ account: Account, report: UsageReport?, theme: RowTheme) -> String? {
        guard !theme.plain,
              let row = report?.accounts.first(where: { $0.number == account.number }) else { return nil }
        return PopupGlyph.text(theme.cashIcon) + Int(row.estimatedUSD).formatted()
    }

    /// The row's windows in popup order — session, weekly, then each
    /// scoped (per-model) one — with the theme's labels and colours.
    private static func windows(_ account: Account, theme: RowTheme) -> [ActivityWindow] {
        guard let u = account.usage else { return [] }
        var out: [ActivityWindow] = []
        if let w = u.fiveHour {
            out.append(ActivityWindow(label: theme.plain ? "5h" : PopupGlyph.text(theme.sessionLabel),
                                      color: theme.sessionColor, pct: w.pct, reset: ResetLabel.compact(w)))
        }
        if let w = u.sevenDay {
            out.append(ActivityWindow(label: theme.plain ? "7d" : PopupGlyph.text(theme.weeklyLabel),
                                      color: theme.weeklyColor, pct: w.pct, reset: ResetLabel.compact(w)))
        }
        for w in u.scoped ?? [] {
            let name = theme.modelName(w.name)
            out.append(ActivityWindow(label: theme.plain ? name : PopupGlyph.text(theme.scopedPrefix) + name,
                                      color: theme.scopedColor, pct: w.pct, reset: ResetLabel.compact(w)))
        }
        return out
    }
}
