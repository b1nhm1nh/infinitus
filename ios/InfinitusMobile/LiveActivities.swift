import ActivityKit
import Foundation
import os
import InfinitusCore
import InfinitusUI

/// Drives the two Live Activities (#1 all-dead countdown, #2 working
/// sessions) from each mirror refresh. No push pipeline: the app
/// updates while it runs, the countdown ticks natively on the lock
/// screen (`Text(timerInterval:)`), and `staleDate` lets iOS grey out a
/// working activity the app hasn't refreshed for a while. Pushed
/// updates (APNs from the Mac) are the follow-up if the budget wants it.
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

    func sync(fleet: MirrorFleetModel?, machine: String) {
        guard let fleet else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            log.notice("live activities disabled for this app")
            return
        }
        syncRevival(fleet: fleet, machine: machine)
        syncWorking(fleet: fleet, machine: machine)
    }

    // MARK: #1

    private func syncRevival(fleet: MirrorFleetModel, machine: String) {
        let allDead = fleet.nextCandidate == nil
        if allDead, let rec = fleet.nextRecovery, let at = WeeklyRoll.parse(rec.at), at > Date() {
            let state = RevivalActivity.ContentState(
                reviver: Self.name(of: rec.number, in: fleet.accounts),
                revivesAt: at,
                sessions: fleet.liveSessions?.total ?? 0,
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

    private func syncWorking(fleet: MirrorFleetModel, machine: String) {
        let busy = fleet.liveSessions?.busy ?? 0
        if busy > 0, let active = fleet.accounts.first(where: { $0.active }) {
            let (label, pct) = Self.bindingWindow(active) ?? ("5h", 0)
            let state = WorkingActivity.ContentState(
                active: Self.name(of: active),
                plan: active.plan,
                bindingLabel: label,
                bindingPct: pct,
                busy: busy,
                total: fleet.liveSessions?.total ?? busy,
                next: fleet.nextCandidate.map { Self.name(of: $0, in: fleet.accounts) })
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

    /// Switch, ≥5-point move of the binding window, or session counts.
    private static func differs(_ a: WorkingActivity.ContentState, _ b: WorkingActivity.ContentState) -> Bool {
        a.active != b.active || a.next != b.next || a.busy != b.busy || a.total != b.total
            || a.bindingLabel != b.bindingLabel || abs(a.bindingPct - b.bindingPct) >= 5
    }

    private static func name(of number: Int, in accounts: [Account]) -> String {
        accounts.first { $0.number == number }.map(name(of:)) ?? "#\(number)"
    }

    private static func name(of account: Account) -> String {
        account.alias ?? String(account.email.prefix(while: { $0 != "@" }))
    }

    /// The window closest to its limit, plain labels (the lock screen
    /// has no theme).
    private static func bindingWindow(_ account: Account) -> (String, Double)? {
        guard let u = account.usage else { return nil }
        var all: [(String, Double)] = []
        if let w = u.fiveHour { all.append(("5h", w.pct)) }
        if let w = u.sevenDay { all.append(("7d", w.pct)) }
        for w in u.scoped ?? [] { all.append((w.name ?? "?", w.pct)) }
        return all.max { $0.1 < $1.1 }
    }
}
