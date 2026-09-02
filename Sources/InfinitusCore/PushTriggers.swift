import Foundation

/// Away-push triggers beyond account switches (user requests 2026-08-30):
/// all sessions finished, all accounts exhausted, and a warning when the
/// last alive account is close to dying. Pure state machine — snapshot
/// ticks in, message strings out — so the episode/dedup rules run under
/// `swift test`; the app posts each message to Notification Center and
/// through `cswap notify push`.
///
/// Episode rules:
///  - "sessions finished" needs TWO consecutive quiet ticks: busy drops to
///    0 between every turn, and a single-tick trigger would ping the phone
///    on each turn gap.
///  - each condition fires once and re-arms only after it clears (the
///    last-alive warning re-arms below `rearmBelowPct`, hysteresis).
///  - flags are applied at emit time, but state advances regardless — so
///    toggling a trigger on later never fires a stale episode.
///  - "waiting on you" (#17) fires once per session when its status flips
///    to `waiting` (a permission prompt or a question) and re-arms when it
///    leaves that state.
public struct PushTriggers: Sendable {
    public struct Account: Sendable {
        public let number: Int
        public let name: String
        public let dead: Bool
        /// Worst plan-window pct (5h/7d/scoped; spend excluded — a spent
        /// credit cap is a footnote, not a death; see AccountVitals).
        public let worstPct: Double?
        public init(number: Int, name: String, dead: Bool, worstPct: Double?) {
            self.number = number
            self.name = name
            self.dead = dead
            self.worstPct = worstPct
        }
    }

    public struct Flags: Sendable {
        public var sessionsDone: Bool
        public var allDead: Bool
        public var lastAlive: Bool
        public var waiting: Bool
        public init(sessionsDone: Bool = true, allDead: Bool = true,
                    lastAlive: Bool = true, waiting: Bool = true) {
            self.sessionsDone = sessionsDone
            self.allDead = allDead
            self.lastAlive = lastAlive
            self.waiting = waiting
        }
    }

    public static let warnPct = 90.0
    public static let rearmBelowPct = 85.0

    private var sawBusy = false
    private var quietTicks = 0
    private var allDeadAnnounced = false
    private var warnedLastAlive: Int?
    private var announcedWaiting: Set<Int> = []
    private var seededWaiting = false

    public init() {}

    public static func worstPlanPct(_ usage: Usage?) -> Double? {
        guard let usage else { return nil }
        var pcts: [Double] = []
        if let p = usage.fiveHour?.pct { pcts.append(p) }
        if let p = usage.sevenDay?.pct { pcts.append(p) }
        for w in usage.scoped ?? [] { pcts.append(w.pct) }
        return pcts.max()
    }

    public mutating func tick(busy: Int?, total: Int?,
                              accounts: [Account], flags: Flags,
                              sessions: [SessionDetail]? = nil) -> [String] {
        var out: [String] = []

        if let sessions {
            let waiting = sessions.filter { $0.status == "waiting" }
            // The first look seeds silently: a session that was already
            // waiting when the app launched is not news, and a relaunch
            // must not re-push every stale prompt.
            let seeded = seededWaiting
            seededWaiting = true
            for session in waiting where !announcedWaiting.contains(session.pid) {
                announcedWaiting.insert(session.pid)
                if flags.waiting, seeded {
                    let repo = URL(fileURLWithPath: session.cwd).lastPathComponent
                    out.append("waiting on you — \(repo) needs an answer")
                }
            }
            announcedWaiting = announcedWaiting.intersection(waiting.map(\.pid))
        }

        if let busy {
            if busy > 0 {
                sawBusy = true
                quietTicks = 0
            } else if sawBusy {
                quietTicks += 1
                if quietTicks >= 2 {
                    sawBusy = false
                    quietTicks = 0
                    if flags.sessionsDone {
                        out.append("all sessions finished — 0 of \(total ?? 0) working")
                    }
                }
            }
        }

        if !accounts.isEmpty, accounts.allSatisfy(\.dead) {
            if !allDeadAnnounced {
                allDeadAnnounced = true
                if flags.allDead {
                    out.append("all \(accounts.count) accounts exhausted — nothing left to switch to")
                }
            }
        } else {
            allDeadAnnounced = false
        }

        let alive = accounts.filter { !$0.dead }
        if alive.count == 1, let last = alive.first,
           let pct = last.worstPct, pct >= Self.warnPct {
            if warnedLastAlive != last.number {
                warnedLastAlive = last.number
                if flags.lastAlive {
                    out.append("last account standing — \(last.name) at \(Int(pct.rounded()))%")
                }
            }
        } else if alive.count != 1
            || (alive.first?.worstPct ?? 0) < Self.rearmBelowPct {
            warnedLastAlive = nil
        }

        return out
    }
}
