import Foundation

/// Run-rate projection (the "prediction model", 2026-09-03): at the
/// current burn, when does each window of the active account hit its
/// limit, and when would the whole fleet be out. Built from the same
/// burn numbers the planner uses (`WindowTelemetry.burnRate`) so the
/// popup never shows two times for one event. Estimates from a short
/// lookback, never truth — every consumer says "at this pace".
public struct UsageForecast: Codable, Sendable, Equatable {
    public struct Window: Codable, Sendable, Equatable {
        /// `"5h"`, `"7d"`, or a scoped window's display name ("Fable").
        public let name: String
        public let pct: Double
        /// Measured burn, pct per hour; nil when there is too little
        /// history inside the current window to tell.
        public let ratePctPerHour: Double?
        public let resetsAt: Double?
        /// Epoch seconds the window reaches 100% at this pace; nil when
        /// the rate is unknown/zero, or when the reset lands first.
        public let hitsAt: Double?
        public init(name: String, pct: Double, ratePctPerHour: Double?,
                    resetsAt: Double?, hitsAt: Double?) {
            self.name = name
            self.pct = pct
            self.ratePctPerHour = ratePctPerHour
            self.resetsAt = resetsAt
            self.hitsAt = hitsAt
        }
    }

    public struct AccountLine: Codable, Sendable, Equatable {
        public let number: Int
        public let email: String
        public let windows: [Window]
        /// The first limit to bind — what the planner's `bindAt` is.
        public var bindsAt: Double? { windows.compactMap(\.hitsAt).min() }
        public init(number: Int, email: String, windows: [Window]) {
            self.number = number
            self.email = email
            self.windows = windows
        }
    }

    public let computedAt: Double
    /// The active account's projection; nil when no account is active.
    public let active: AccountLine?
    /// When every usable account's weekly headroom is gone at the active
    /// account's weekly pace (sequential drain, headroom-richest last);
    /// nil without a measurable weekly rate.
    public let allDeadAt: Double?
    /// What the numbers rest on, for the tooltip / pane footer.
    public let basis: String

    public init(computedAt: Double, active: AccountLine?, allDeadAt: Double?, basis: String) {
        self.computedAt = computedAt
        self.active = active
        self.allDeadAt = allDeadAt
        self.basis = basis
    }

    // MARK: building

    /// One account as the model sees it: current windows plus the burn
    /// measured for each (keyed like `Window.name`).
    public struct AccountInput: Sendable, Equatable {
        public let number: Int
        public let email: String
        public let active: Bool
        public let disabled: Bool
        public let fiveHour: UsageSample.Window?
        public let sevenDay: UsageSample.Window?
        public let scoped: [String: UsageSample.Window]
        public init(number: Int, email: String, active: Bool, disabled: Bool,
                    fiveHour: UsageSample.Window?, sevenDay: UsageSample.Window?,
                    scoped: [String: UsageSample.Window]) {
            self.number = number
            self.email = email
            self.active = active
            self.disabled = disabled
            self.fiveHour = fiveHour
            self.sevenDay = sevenDay
            self.scoped = scoped
        }
    }

    public static let fiveHourLookback: Double = 3600
    public static let weeklyLookback: Double = 24 * 3600

    /// `rates` maps window name → pct/hour for the ACTIVE account (the
    /// fleet drains at that pace once it moves on). Missing keys mean
    /// "unknown", which projects nothing rather than something wrong.
    public static func build(accounts: [AccountInput], rates: [String: Double],
                             now: Double) -> UsageForecast {
        let basis = "5h pace from the last hour, weekly pace from the last 24h; "
            + "fleet drains weekly headroom in headroom order at the active account's pace"
        guard let act = accounts.first(where: { $0.active }) else {
            return UsageForecast(computedAt: now, active: nil, allDeadAt: nil, basis: basis)
        }
        var windows: [Window] = []
        if let w = act.fiveHour { windows.append(project("5h", w, rate: rates["5h"], now: now)) }
        if let w = act.sevenDay { windows.append(project("7d", w, rate: rates["7d"], now: now)) }
        for (name, w) in act.scoped.sorted(by: { $0.key < $1.key }) {
            windows.append(project(name, w, rate: rates[name], now: now))
        }
        let line = AccountLine(number: act.number, email: act.email, windows: windows)
        return UsageForecast(computedAt: now, active: line,
                             allDeadAt: allDead(accounts: accounts, rates: rates, now: now),
                             basis: basis)
    }

    static func project(_ name: String, _ w: UsageSample.Window, rate: Double?,
                        now: Double) -> Window {
        var hits: Double?
        if w.pct >= 100 {
            hits = now
        } else if let rate, rate > 0 {
            let at = now + (100 - w.pct) / rate * 3600
            if let reset = w.resetsAt, reset <= at { hits = nil } else { hits = at }
        }
        return Window(name: name, pct: w.pct, ratePctPerHour: rate, resetsAt: w.resetsAt, hitsAt: hits)
    }

    /// Sequential drain of weekly headroom: the active account first, then
    /// the others from least to most headroom (the order the fleet would
    /// burn through them). Each account lasts until its first weekly
    /// window (7d or scoped) hits 100% at the active account's pace.
    /// An account already at 100% weekly contributes nothing; a weekly
    /// reset inside the horizon is ignored (reported as such in `basis`).
    static func allDead(accounts: [AccountInput], rates: [String: Double], now: Double) -> Double? {
        let weeklyRates = rates.filter { $0.key != "5h" && $0.value > 0 }
        guard !weeklyRates.isEmpty else { return nil }
        func headroomHours(_ a: AccountInput) -> Double? {
            var hours: [Double] = []
            if let w = a.sevenDay, let r = weeklyRates["7d"] { hours.append(max(0, 100 - w.pct) / r) }
            for (name, w) in a.scoped { if let r = weeklyRates[name] { hours.append(max(0, 100 - w.pct) / r) } }
            return hours.min()
        }
        let usable = accounts.filter { !$0.disabled }
        guard usable.contains(where: { $0.active }) else { return nil }
        let ordered = usable.filter(\.active) + usable.filter { !$0.active }
            .sorted { ($0.sevenDay?.pct ?? 0) > ($1.sevenDay?.pct ?? 0) }
        var cursor = now
        var measured = false
        for a in ordered {
            guard let h = headroomHours(a) else { continue }
            measured = true
            cursor += h * 3600
        }
        return measured ? cursor : nil
    }
}

extension WindowTelemetry {
    /// `burnRate` for any window: the pct/hour of `window(sample)` over the
    /// last `lookback` seconds, measured inside the window's current
    /// reset (a reset in between would make the delta meaningless).
    public static func burnRate(_ samples: [UsageSample], email: String, now: Double,
                                lookback: Double, resetSlack: Double = resetSlack,
                                window: (UsageSample) -> UsageSample.Window?) -> Double? {
        let recent = samples
            .filter { $0.email == email && $0.t >= now - lookback && $0.t <= now }
            .sorted { $0.t < $1.t }
        guard let last = recent.last, let lw = window(last), let lr = lw.resetsAt,
              let first = recent.first(where: { s in
                  window(s)?.resetsAt.map { abs($0 - lr) <= resetSlack } ?? false
              }),
              let fw = window(first),
              last.t - first.t >= 600 else { return nil }
        let delta = lw.pct - fw.pct
        guard delta >= 0 else { return nil }
        return delta / (last.t - first.t) * 3600
    }

    /// Every window's burn for one account, keyed like `UsageForecast.Window.name`:
    /// 5h over the last hour, 7d and scoped over the last 24h.
    public static func burnRates(_ samples: [UsageSample], email: String, now: Double) -> [String: Double] {
        var rates: [String: Double] = [:]
        if let r = burnRate(samples, email: email, now: now, lookback: UsageForecast.fiveHourLookback,
                            window: { $0.fiveHour }) { rates["5h"] = r }
        if let r = burnRate(samples, email: email, now: now, lookback: UsageForecast.weeklyLookback,
                            window: { $0.sevenDay }) { rates["7d"] = r }
        let names = Set(samples.lazy.filter { $0.email == email }.flatMap { $0.scoped?.keys ?? [:].keys })
        for name in names {
            if let r = burnRate(samples, email: email, now: now, lookback: UsageForecast.weeklyLookback,
                                window: { $0.scoped?[name] }) { rates[name] = r }
        }
        return rates
    }
}
