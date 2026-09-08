import Foundation
import WinSDK

/// Balloon notifications via Shell_NotifyIconW with NIF_INFO.
///
/// Windows cannot push to the phone over APNs (Apple `.p8` lives only in
/// one Mac's keychain; `LiveActivityPush` has no non-CryptoKit signing
/// path). Events that would have pushed on the Mac become local tray
/// toasts instead — Option A in `docs/windows-phase-04-push.md`.
///
/// Mac-relay (Option B) is recorded as a decision, not a deliverable:
/// it needs a new inbound authenticated route on the Mac whose payload
/// causes that Mac to send a push on another machine's word, and it
/// re-introduces the 24/7 Mac dependency the Windows port exists to
/// avoid. Do not re-litigate without an explicit ask.
enum TrayNotify {
    /// Sends a balloon. Safe to call when the shell suppresses balloons.
    static func balloon(_ hwnd: HWND, title: String, body: String) {
        var data = NOTIFYICONDATAW()
        data.cbSize = DWORD(MemoryLayout<NOTIFYICONDATAW>.size)
        data.hWnd = hwnd
        data.uID = 1
        data.uFlags = UINT(NIF_INFO)
        data.dwInfoFlags = DWORD(NIIF_INFO)

        withUnsafeMutableBytes(of: &data.szInfo) { raw in
            let slot = raw.bindMemory(to: WCHAR.self)
            let text = Array(body.utf16.prefix(slot.count - 1)) + [0]
            for (index, unit) in text.enumerated() { slot[index] = unit }
        }

        withUnsafeMutableBytes(of: &data.szInfoTitle) { raw in
            let slot = raw.bindMemory(to: WCHAR.self)
            let text = Array(title.utf16.prefix(slot.count - 1)) + [0]
            for (index, unit) in text.enumerated() { slot[index] = unit }
        }

        _ = Shell_NotifyIconW(DWORD(NIM_MODIFY), &data)
    }

    /// Events that would have pushed on the Mac. Composing the toast is
    /// pure and testable; `balloon` is the only Win32 step.
    enum PushEvent: Equatable {
        /// Session flipped to waiting (permission prompt or question).
        case sessionWaiting(pid: Int32, name: String?)
        /// Session vanished while it was mid-turn.
        case sessionStoppedBusy(pid: Int32, name: String?)
        /// Every live session went idle after a stretch of work.
        case sessionsFinished(total: Int)
        /// Every account is exhausted — nothing left to switch to.
        case limitStop(accountCount: Int)
        /// A granted team command was answered on this box.
        case teamCommandAnswered(peer: String, command: String, outcome: String)

        /// The balloon body for this event. No Win32.
        var text: String {
            switch self {
            case .sessionWaiting(let pid, let name):
                return "\(Self.label(pid: pid, name: name)) is waiting for input"
            case .sessionStoppedBusy(let pid, let name):
                return "\(Self.label(pid: pid, name: name)) stopped while busy"
            case .sessionsFinished(let total):
                return "All sessions finished — 0 of \(total) working"
            case .limitStop(let count):
                return "All \(count) accounts exhausted — nothing left to switch to"
            case .teamCommandAnswered(let peer, let command, let outcome):
                return "Team command from \(peer) (\(command)): \(outcome)"
            }
        }

        static func label(pid: Int32, name: String?) -> String {
            name.map { "\($0) (\(pid))" } ?? "Session \(pid)"
        }
    }

    /// Composes the toast body for a push event. Pure string test.
    static func compose(_ event: PushEvent) -> String { event.text }

    /// Decides what (if anything) to announce given the previous and current
    /// session snapshot — pure, testable, no Win32.
    ///
    /// Announce:
    /// - session transitioning to `waiting` (needs user).
    /// - session disappearing while it was `busy` (stopped unexpectedly).
    /// - all sessions finishing work, only when `announceSessionsFinished`
    ///   is on. Defaults off: "session finished" is noise on a box with
    ///   seven live sessions (`docs/windows-phase-04-push.md`).
    ///
    /// Quiet about:
    /// - routine `busy` <-> `idle` churn (unless the finished knob is on
    ///   and every session just went idle).
    /// - sessions disappearing from `idle` or other non-busy states.
    /// - existing sessions staying in `waiting` across ticks.
    static func transitions(previous: [Int32: String], current: [Int32: String],
                            names: [Int32: String] = [:],
                            announceSessionsFinished: Bool = false) -> [String] {
        // An empty `previous` is the first tick, not a world where every
        // session just changed: announcing then would greet the user with
        // a balloon per already-waiting session at every launch.
        guard !previous.isEmpty else { return [] }
        var lines: [String] = []

        // Announce a session transitioning to waiting
        for (pid, status) in current.sorted(by: { $0.key < $1.key }) {
            if status == "waiting" && previous[pid] != nil && previous[pid] != "waiting" {
                lines.append(compose(.sessionWaiting(pid: pid, name: names[pid])))
            }
        }

        // Announce a session disappearing while it was busy
        for (pid, prevStatus) in previous.sorted(by: { $0.key < $1.key }) {
            if current[pid] == nil && prevStatus == "busy" {
                lines.append(compose(.sessionStoppedBusy(pid: pid, name: names[pid])))
            }
        }

        // All sessions finished: previous had work, current has none.
        // Quiet unless the knob is on — default matches the spec.
        if announceSessionsFinished,
           previous.values.contains("busy"),
           !current.isEmpty,
           !current.values.contains("busy") {
            lines.append(compose(.sessionsFinished(total: current.count)))
        }

        return lines
    }

    /// Limit-stop toast when the fleet just went all-dead. First look
    /// (`previousAllDead` with empty previous) stays silent — same seed
    /// rule as `PushTriggers`.
    static func limitStop(previousAllDead: Bool, currentAllDead: Bool,
                          accountCount: Int) -> String? {
        guard currentAllDead, !previousAllDead, accountCount > 0 else { return nil }
        return compose(.limitStop(accountCount: accountCount))
    }

    /// Toast for a granted team command that this box just answered.
    static func teamCommandAnswered(peer: String, command: String,
                                    outcome: String) -> String {
        compose(.teamCommandAnswered(peer: peer, command: command, outcome: outcome))
    }
}
