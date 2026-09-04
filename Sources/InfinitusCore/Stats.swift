import Foundation

/// Engineering metrics (user 2026-09-04: PRs, commits, lines, human vs
/// relayed messages, sessions — per day/week/month/year). One `Day` per
/// local calendar day; days add, so any period is a sum. Pure — the
/// scanners in StatsScanner / RepoStats / StatsEvents produce days, the
/// app merges and folds them.
public enum Stats {
    public struct Day: Codable, Equatable, Sendable {
        // Messages
        public var humanMessages = 0      // typed at the keyboard
        public var phoneMessages = 0      // typed on the phone (human too)
        public var agentMessages = 0      // other Claude sessions
        public var nudges = 0             // the app's own "[Infinitus] …"
        // Work
        public var turns = 0
        public var toolCalls: [String: Int] = [:]
        public var toolErrors = 0
        public var questions = 0          // AskUserQuestion
        public var denials = 0            // tool calls the user denied
        public var waitingSeconds = 0.0   // turn end → next human/phone message, ≤ 8 h each
        public var subagents = 0
        public var compactions = 0
        public var retries = 0
        public var longestUnattended = 0  // most tool calls between two human messages
        // Tokens
        public var inputTokens = 0
        public var outputTokens = 0
        public var usd = 0.0
        // Sessions
        public var sessions: Set<String> = []
        public var sessionTally = 0       // compact form for the phone: set emptied, count kept
        public var sessionSeconds = 0.0
        public var sessionBuckets = [0, 0, 0, 0]   // <15m, 15-60m, 1-4h, >4h; one session per file-day
        public var hours: [Int] = Array(repeating: 0, count: 168)   // weekday(Mon=0)*24 + hour
        // Git
        public var commits = 0
        public var linesAdded = 0
        public var linesRemoved = 0
        public var filesTouched = 0
        public var coAuthoredByClaude = 0
        public var reverts = 0
        public var repos: Set<String> = []
        public var repoTally = 0          // compact form for the phone: set emptied, count kept
        // GitHub
        public var prsOpened = 0
        public var prsMerged = 0
        public var mergeHoursTotal = 0.0
        public var mergeCount = 0
        // App events
        public var switches = 0
        public var limitStops = 0
        public var revivals = 0
        public var ignites = 0
        public var resumes = 0
        public var minutesLostToLimits = 0.0

        public init() {}

        public static func + (a: Day, b: Day) -> Day {
            var c = a
            c.humanMessages += b.humanMessages
            c.phoneMessages += b.phoneMessages
            c.agentMessages += b.agentMessages
            c.nudges += b.nudges
            c.turns += b.turns
            c.toolCalls.merge(b.toolCalls, uniquingKeysWith: +)
            c.toolErrors += b.toolErrors
            c.questions += b.questions
            c.denials += b.denials
            c.waitingSeconds += b.waitingSeconds
            c.subagents += b.subagents
            c.compactions += b.compactions
            c.retries += b.retries
            c.longestUnattended = max(a.longestUnattended, b.longestUnattended)
            c.inputTokens += b.inputTokens
            c.outputTokens += b.outputTokens
            c.usd += b.usd
            c.sessions.formUnion(b.sessions)
            c.sessionSeconds += b.sessionSeconds
            for i in 0..<4 { c.sessionBuckets[i] = a.sessionBuckets[i] + b.sessionBuckets[i] }
            for i in 0..<168 { c.hours[i] = a.hours[i] + b.hours[i] }
            c.commits += b.commits
            c.linesAdded += b.linesAdded
            c.linesRemoved += b.linesRemoved
            c.filesTouched += b.filesTouched
            c.coAuthoredByClaude += b.coAuthoredByClaude
            c.reverts += b.reverts
            c.repos.formUnion(b.repos)
            c.prsOpened += b.prsOpened
            c.prsMerged += b.prsMerged
            c.mergeHoursTotal += b.mergeHoursTotal
            c.mergeCount += b.mergeCount
            c.switches += b.switches
            c.limitStops += b.limitStops
            c.revivals += b.revivals
            c.ignites += b.ignites
            c.resumes += b.resumes
            c.minutesLostToLimits += b.minutesLostToLimits
            return c
        }

        // Derived — nil when the denominator is zero (tiles show "—").
        public var messages: Int { humanMessages + phoneMessages }
        public var totalToolCalls: Int { toolCalls.values.reduce(0, +) }
        public var sessionCount: Int { sessions.isEmpty ? sessionTally : sessions.count }
        public var repoCount: Int { repos.isEmpty ? repoTally : repos.count }
        public var messagesPerCommit: Double? { ratio(Double(messages), Double(commits)) }
        public var toolCallsPerHumanMessage: Double? { ratio(Double(totalToolCalls), Double(messages)) }
        public var usdPerCommit: Double? { ratio(usd, Double(commits)) }
        public var usdPerPR: Double? { ratio(usd, Double(prsMerged)) }
        public var tokensPerLine: Double? { ratio(Double(outputTokens), Double(linesAdded + linesRemoved)) }
        public var humanShare: Double? { ratio(Double(messages), Double(messages + agentMessages + nudges)) }
        public var meanMergeHours: Double? { ratio(mergeHoursTotal, Double(mergeCount)) }
        private func ratio(_ n: Double, _ d: Double) -> Double? { d > 0 ? n / d : nil }

        /// 0..3 by <15m, <1h, <4h, else >4h.
        public static func sessionBucket(seconds: Double) -> Int {
            if seconds < 900 { return 0 }
            if seconds < 3600 { return 1 }
            if seconds < 14400 { return 2 }
            return 3
        }
    }

    public enum Period: String, Codable, CaseIterable, Sendable {
        case day, week, month, year
        public var title: String {
            switch self {
            case .day: "Today"
            case .week: "This week"
            case .month: "This month"
            case .year: "This year"
            }
        }
    }

    /// One day in a period's series — a key and its facts.
    public struct DayPoint: Codable, Equatable, Sendable {
        public let key: String
        public let day: Day
        public init(key: String, day: Day) { self.key = key; self.day = day }
    }

    public struct Summary: Codable, Equatable, Sendable {
        public let period: Period
        public let from: String          // first day key, inclusive
        public let to: String            // last day key, inclusive
        public var total: Day
        public var previous: Day         // the calendar period before `from`
        public var daily: [DayPoint]     // every day from `from` to `to`, empty days included
        public var streak: Int           // consecutive days ending today with a commit or a human message
    }

    /// What travels to the phone / the wall: the four periods without
    /// their day series.
    public struct Bundle: Codable, Equatable, Sendable {
        public let computedAt: Date
        public let periods: [Summary]
        public init(days: [String: Day], now: Date = Date(), calendar: Calendar = .current) {
            computedAt = now
            periods = Period.allCases.map { p in
                var s = fold(days: days, period: p, now: now, calendar: calendar)
                s.daily = []
                s.total.sessionTally = s.total.sessions.count
                s.total.sessions = []
                s.total.repoTally = s.total.repos.count
                s.total.repos = []
                s.previous.sessionTally = s.previous.sessions.count
                s.previous.sessions = []
                s.previous.repoTally = s.previous.repos.count
                s.previous.repos = []
                return s
            }
        }
        public func summary(_ p: Period) -> Summary? { periods.first { $0.period == p } }
    }

    // MARK: keys

    nonisolated(unsafe) private static var keyFormatters: [TimeZone: DateFormatter] = [:]
    private static let keyLock = NSLock()

    private static func keyFormatter(_ calendar: Calendar) -> DateFormatter {
        keyLock.lock(); defer { keyLock.unlock() }
        if let f = keyFormatters[calendar.timeZone] { return f }
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        keyFormatters[calendar.timeZone] = f
        return f
    }

    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        keyFormatter(calendar).string(from: date)
    }

    public static func date(fromDayKey key: String, calendar: Calendar = .current) -> Date? {
        keyFormatter(calendar).date(from: key)
    }

    /// Monday = 0 … Sunday = 6, times 24, plus the hour.
    public static func hourSlot(_ date: Date, calendar: Calendar = .current) -> Int {
        let weekday = (calendar.component(.weekday, from: date) + 5) % 7
        return weekday * 24 + calendar.component(.hour, from: date)
    }

    // MARK: folding

    public static func fold(days: [String: Day], period: Period, now: Date = Date(),
                            calendar: Calendar = .current) -> Summary {
        let (start, end) = range(period, now: now, calendar: calendar)
        let previousStart: Date
        switch period {
        case .day:
            previousStart = calendar.date(byAdding: .day, value: -1, to: start)!
        case .week:
            previousStart = calendar.date(byAdding: .day, value: -7, to: start)!
        case .month:
            previousStart = calendar.date(byAdding: .month, value: -1, to: start)!
        case .year:
            previousStart = calendar.date(byAdding: .year, value: -1, to: start)!
        }
        let previousEnd = start
        var total = Day(), previous = Day(), daily: [DayPoint] = []
        var cursor = start
        while cursor < end {
            let key = dayKey(cursor, calendar: calendar)
            let day = days[key] ?? Day()
            total = total + day
            daily.append(DayPoint(key: key, day: day))
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
        }
        cursor = previousStart
        while cursor < previousEnd {
            previous = previous + (days[dayKey(cursor, calendar: calendar)] ?? Day())
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
        }
        var streak = 0
        var back = calendar.startOfDay(for: now)
        while let d = days[dayKey(back, calendar: calendar)], d.commits > 0 || d.messages > 0 {
            streak += 1
            back = calendar.date(byAdding: .day, value: -1, to: back)!
        }
        let last = calendar.date(byAdding: .day, value: -1, to: end)!
        return Summary(period: period, from: dayKey(start, calendar: calendar),
                       to: dayKey(last, calendar: calendar), total: total, previous: previous,
                       daily: daily, streak: streak)
    }

    /// [start, end) of the period containing `now`; weeks start on the
    /// calendar's first weekday.
    static func range(_ period: Period, now: Date, calendar: Calendar) -> (Date, Date) {
        let today = calendar.startOfDay(for: now)
        switch period {
        case .day:
            return (today, calendar.date(byAdding: .day, value: 1, to: today)!)
        case .week:
            let comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: today)
            let start = calendar.date(from: comps)!
            return (start, calendar.date(byAdding: .day, value: 7, to: start)!)
        case .month:
            let start = calendar.date(from: calendar.dateComponents([.year, .month], from: today))!
            return (start, calendar.date(byAdding: .month, value: 1, to: start)!)
        case .year:
            let start = calendar.date(from: calendar.dateComponents([.year], from: today))!
            return (start, calendar.date(byAdding: .year, value: 1, to: start)!)
        }
    }
}
