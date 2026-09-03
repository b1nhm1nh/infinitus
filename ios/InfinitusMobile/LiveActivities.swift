import ActivityKit
import Foundation
import InfinitusCore
import os

/// Drives the two Live Activities (#1 all-dead countdown, #2 working
/// sessions) from each mirror refresh while the app runs, and hands
/// their APNs tokens to the Mac so it can keep them moving (and start
/// them, iOS 17.2+) with the app closed — LiveActivityPusher on the Mac.
/// Content is built by InfinitusCore's `LiveActivityBuilder`, the same
/// code the Mac's pushes use, themed with the phone's theme.
@MainActor
final class LiveActivities {
    static let shared = LiveActivities()

    private let log = Logger(subsystem: "com.huuloc.infinitus.mobile", category: "live-activity")
    private var revival: Activity<RevivalActivity>?
    private var working: Activity<WorkingActivity>?
    private var tokenWatchers: [String: Task<Void, Never>] = [:]
    private var themeID: String?

    private init() {
        // Adopt activities that survived an app relaunch (or that the
        // Mac started by push while the app was closed).
        revival = Activity<RevivalActivity>.activities.first
        working = Activity<WorkingActivity>.activities.first
        if let revival { watchToken(of: revival, kind: .revival) }
        if let working { watchToken(of: working, kind: .working) }
        watchPushToStartTokens()
    }

    func sync(fleet: MirrorFleetModel?, machine: String, tokenRate: TokenRate?) {
        guard let fleet else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            log.notice("live activities disabled for this app")
            return
        }
        themeID = fleet.rowTheme.id
        // A push may have started/ended one behind our back.
        if working?.activityState != .active { working = Activity<WorkingActivity>.activities.first { $0.activityState == .active } }
        if revival?.activityState != .active { revival = Activity<RevivalActivity>.activities.first { $0.activityState == .active } }
        let engineFleet = EngineFleet(engineID: fleet.id, provider: fleet.provider, accounts: fleet.accounts,
                                      activeNumber: fleet.activeNumber, nextCandidate: fleet.nextCandidate,
                                      nextRecovery: fleet.nextRecovery, liveSessions: fleet.liveSessions, raw: nil)
        syncRevival(LiveActivityBuilder.revival(fleet: engineFleet, theme: fleet.rowTheme), machine: machine)
        syncWorking(LiveActivityBuilder.working(fleet: engineFleet, theme: fleet.rowTheme,
                                                report: fleet.report, tokenRate: tokenRate), machine: machine)
    }

    // MARK: #1

    private func syncRevival(_ state: RevivalActivityState?, machine: String) {
        if let state {
            let content = ActivityContent(state: state, staleDate: state.revivesAt.addingTimeInterval(60))
            if let revival, revival.activityState == .active {
                if revival.content.state != state { Task { await revival.update(content) } }
            } else {
                do {
                    let activity = try Activity.request(attributes: RevivalActivity(machine: machine),
                                                        content: content, pushType: .token)
                    revival = activity
                    watchToken(of: activity, kind: .revival)
                    log.notice("revival activity started: \(state.reviver) at \(state.revivesAt)")
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

    private func syncWorking(_ state: WorkingActivityState?, machine: String) {
        if let state {
            let content = ActivityContent(state: state,
                                          staleDate: Date().addingTimeInterval(LiveActivityBuilder.workingStale))
            if let working, working.activityState == .active {
                if LiveActivityBuilder.differs(working.content.state, state) { Task { await working.update(content) } }
            } else {
                do {
                    let activity = try Activity.request(attributes: WorkingActivity(machine: machine),
                                                        content: content, pushType: .token)
                    working = activity
                    watchToken(of: activity, kind: .working)
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

    // MARK: push tokens → the Mac

    private func watchToken<A: ActivityAttributes>(of activity: Activity<A>, kind: ActivityPushRegistration.Kind) {
        tokenWatchers[kind.rawValue]?.cancel()
        tokenWatchers[kind.rawValue] = Task { [weak self] in
            for await token in activity.pushTokenUpdates {
                await self?.register(kind: kind, token: token)
            }
        }
    }

    /// iOS 17.2+: one token per activity type that lets the Mac START an
    /// activity while the app is closed.
    private func watchPushToStartTokens() {
        guard #available(iOS 17.2, *) else { return }
        tokenWatchers["working-start"] = Task { [weak self] in
            for await token in Activity<WorkingActivity>.pushToStartTokenUpdates {
                await self?.register(kind: .workingStart, token: token)
            }
        }
        tokenWatchers["revival-start"] = Task { [weak self] in
            for await token in Activity<RevivalActivity>.pushToStartTokenUpdates {
                await self?.register(kind: .revivalStart, token: token)
            }
        }
    }

    private func register(kind: ActivityPushRegistration.Kind, token: Data) async {
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif
        let registration = ActivityPushRegistration(
            kind: kind, token: token.map { String(format: "%02x", $0) }.joined(),
            deviceId: NetworkFleetMirror.deviceId, deviceName: NetworkFleetMirror.deviceName,
            environment: environment, themeID: themeID)
        let ok = await NetworkFleetMirror.shared.registerActivityToken(registration)
        log.notice("\(kind.rawValue) token \(ok ? "registered with the Mac" : "NOT registered — Mac unreachable")")
    }
}
