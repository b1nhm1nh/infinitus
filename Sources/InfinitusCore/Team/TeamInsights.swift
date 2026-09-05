import Foundation

/// Spec §8.2–8.4, computed from a `TeamReader` — pure, so the pane, the
/// phone (via aggregates) and the CLI agree. Money is the app's own
/// estimate (usage-cost caveat), never billing truth.
public enum TeamInsights {
    // MARK: comparison

    public struct MemberRow: Equatable, Sendable {
        public var kid: String
        public var name: String
        public var role: String
        public var summary: Stats.Summary
        public var online: Bool
        public var sessionsNow: Int
        public var blockers: [String]
        public var crashes: Int
        public var lastPublished: Int?
    }

    /// One row per roster member (and per removed sender still readable),
    /// leaders first, then by name.
    public static func comparison(_ reader: TeamReader, period: Stats.Period, now: Date = Date(),
                                  calendar: Calendar = .current) -> [MemberRow] {
        reader.members.values.map { m in
            MemberRow(kid: m.kid, name: m.name, role: m.role,
                      summary: Stats.fold(days: m.days, period: period, now: now, calendar: calendar),
                      online: isOn(m, now: now), sessionsNow: m.now?.sessions.count ?? 0,
                      blockers: m.now?.blockers ?? [], crashes: m.crashes.count, lastPublished: m.lastPublished)
        }
        .sorted { x, y in
            (x.role == "leader" ? 0 : 1, x.name, x.kid) < (y.role == "leader" ? 0 : 1, y.name, y.kid)
        }
    }

    // MARK: who is on

    /// A `now.json` older than this is stale: the member is off.
    public static let onlineWindow = 15 * 60

    public static func isOn(_ m: TeamReader.Member, now: Date) -> Bool {
        guard let n = m.now else { return false }
        return Int(now.timeIntervalSince1970) - n.at <= onlineWindow && !n.sessions.isEmpty
    }

    public static func whoIsOn(_ reader: TeamReader, now: Date = Date()) -> [TeamReader.Member] {
        reader.members.values.filter { isOn($0, now: now) }.sorted { $0.name == $1.name ? $0.kid < $1.kid : $0.name < $1.name }
    }

    // MARK: leaderboards

    public enum Metric: String, CaseIterable, Codable, Sendable {
        case usd, outputTokens, commits, prsMerged, linesAdded, messages, toolCalls, waitingMinutes, sessions

        public var title: String {
            switch self {
            case .usd: "Spend (est.)"
            case .outputTokens: "Output tokens"
            case .commits: "Commits"
            case .prsMerged: "PRs merged"
            case .linesAdded: "Lines added"
            case .messages: "Messages"
            case .toolCalls: "Tool calls"
            case .waitingMinutes: "Minutes waiting"
            case .sessions: "Sessions"
            }
        }

        public func value(_ d: Stats.Day) -> Double {
            switch self {
            case .usd: d.usd
            case .outputTokens: Double(d.outputTokens)
            case .commits: Double(d.commits)
            case .prsMerged: Double(d.prsMerged)
            case .linesAdded: Double(d.linesAdded)
            case .messages: Double(d.messages)
            case .toolCalls: Double(d.totalToolCalls)
            case .waitingMinutes: d.waitingSeconds / 60
            case .sessions: Double(d.sessionCount)
            }
        }
    }

    public struct LeaderboardRow: Equatable, Sendable {
        public var kid: String
        public var name: String
        public var value: Double
    }

    public static func leaderboard(_ rows: [MemberRow], metric: Metric) -> [LeaderboardRow] {
        rows.map { LeaderboardRow(kid: $0.kid, name: $0.name, value: metric.value($0.summary.total)) }
            .sorted { $0.value == $1.value ? $0.name < $1.name : $0.value > $1.value }
    }

    // MARK: repos

    public struct RepoRow: Equatable, Sendable {
        public struct Share: Equatable, Sendable {
            public var kid: String
            public var name: String
            public var usd: Double
            public var minutes: Int
        }
        public var project: String
        public var usd: Double
        public var minutes: Int
        /// By effort, descending.
        public var members: [Share]
    }

    /// Who works where, from every member's session index: sessions that
    /// started inside the period, grouped by project, by effort.
    public static func repos(_ reader: TeamReader, period: Stats.Period, now: Date = Date(),
                             calendar: Calendar = .current) -> [RepoRow] {
        let start = Int(Stats.range(period, now: now, calendar: calendar).0.timeIntervalSince1970)
        var byProject: [String: [String: RepoRow.Share]] = [:]
        for m in reader.members.values {
            for s in m.sessions where s.startedAt >= start {
                var share = byProject[s.project, default: [:]][m.kid] ?? RepoRow.Share(kid: m.kid, name: m.name, usd: 0, minutes: 0)
                share.usd += s.usd
                share.minutes += s.busyMinutes
                byProject[s.project, default: [:]][m.kid] = share
            }
        }
        return byProject.map { project, shares in
            let members = shares.values.sorted { $0.usd == $1.usd ? $0.name < $1.name : $0.usd > $1.usd }
            return RepoRow(project: project, usd: members.reduce(0) { $0 + $1.usd }, minutes: members.reduce(0) { $0 + $1.minutes }, members: members)
        }
        .sorted { $0.usd == $1.usd ? $0.project < $1.project : $0.usd > $1.usd }
    }

    // MARK: blockers

    public struct Blocker: Equatable, Sendable {
        public var kid: String
        public var name: String
        /// "aws" | "limit" | "waiting" | "crash" | "other"
        public var kind: String
        public var text: String
    }

    /// Every fresh member's blockers (spec §8.3): what its pop-out shows,
    /// sessions waiting on a prompt, crashes today. Stale members are
    /// skipped so an old `now.json` cannot keep a blocker alive.
    public static func blockers(_ reader: TeamReader, now: Date = Date()) -> [Blocker] {
        var out: [Blocker] = []
        for m in reader.members.values.sorted(by: { $0.name == $1.name ? $0.kid < $1.kid : $0.name < $1.name }) {
            guard let n = m.now, Int(now.timeIntervalSince1970) - n.at <= onlineWindow else { continue }
            for text in n.blockers {
                let kind = text.hasPrefix("AWS") ? "aws" : text.contains("limited") ? "limit" : "other"
                out.append(Blocker(kid: m.kid, name: m.name, kind: kind, text: text))
            }
            for s in n.sessions where s.status == "waiting" {
                out.append(Blocker(kid: m.kid, name: m.name, kind: "waiting", text: "\(s.name ?? s.project) is waiting for you"))
            }
            if n.crashesToday > 0 {
                out.append(Blocker(kid: m.kid, name: m.name, kind: "crash", text: "\(n.crashesToday) crash\(n.crashesToday == 1 ? "" : "es") today"))
            }
        }
        return out
    }

    // MARK: cost, hours

    public struct Cost: Equatable, Sendable {
        public struct MemberCost: Equatable, Sendable {
            public var kid: String
            public var name: String
            public var usd: Double
        }
        public var total: Double
        /// Descending, then by name.
        public var byMember: [MemberCost]
        public var byModel: [String: Double]
        public var byRepo: [String: Double]
    }

    public static func cost(_ rows: [MemberRow], repos: [RepoRow]) -> Cost {
        var byModel: [String: Double] = [:]
        for r in rows { for (model, tally) in r.summary.total.byModel { byModel[model, default: 0] += tally.usd } }
        let byMember = rows.map { (r: MemberRow) -> Cost.MemberCost in Cost.MemberCost(kid: r.kid, name: r.name, usd: r.summary.total.usd) }
            .sorted { (x: Cost.MemberCost, y: Cost.MemberCost) -> Bool in x.usd == y.usd ? x.name < y.name : x.usd > y.usd }
        return Cost(total: rows.reduce(0) { $0 + $1.summary.total.usd }, byMember: byMember, byModel: byModel,
                    byRepo: Dictionary(repos.map { ($0.project, $0.usd) }, uniquingKeysWith: +))
    }

    /// The team's 168-slot heatmap (weekday × hour) for the rows' period.
    public static func hours(_ rows: [MemberRow]) -> [Int] {
        var out = Array(repeating: 0, count: 168)
        for r in rows { for (i, v) in r.summary.total.hours.prefix(168).enumerated() { out[i] += v } }
        return out
    }

    // MARK: members' view (§8.4)

    public struct ShareRow: Equatable, Sendable {
        public var kid: String
        public var name: String
        /// Kinds this teammate's audiences include me in, sorted.
        public var kinds: [String]
    }

    /// What each teammate shares TO `me`, read off their `now.sharesTo`
    /// (a member with no fresh `now.json` shows an empty row). Leaders
    /// are never listed as a teammate here — this is the members' view
    /// of each other (spec §8.4), not the leaders' comparison.
    public static func sharedWithMe(_ reader: TeamReader, roster: TeamRoster, me: String) -> [ShareRow] {
        roster.members.filter { $0.keys.kid != me }.map { member in
            let shares = reader.members[member.keys.kid]?.now?.sharesTo ?? [:]
            let kinds = shares.filter { _, target in
                switch target {
                case .team: true
                case .leaders: roster.isLeader(me)
                case .members(let kids): kids.contains(me)
                }
            }.keys.sorted()
            return ShareRow(kid: member.keys.kid, name: member.name, kinds: kinds)
        }
        .sorted { $0.name == $1.name ? $0.kid < $1.kid : $0.name < $1.name }
    }
}
