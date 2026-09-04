import Foundation

/// One tile/group catalogue shared by the Mac Stats pane and the phone
/// Stats screen (fix round 1, 2026-09-04): same names, same key paths,
/// same formulas — the two surfaces render this, never their own copy.
/// Everything view-specific (sparkline charts, the hour heatmap, period
/// picker, refresh) stays in each platform's own file.
extension Stats {
    public enum Presentation {
        public struct Tile: Identifiable, Equatable, Sendable {
            public let id: String   // the tile's display name
            public let value: String
            public let delta: String?
            /// Per-day values for the sparkline — empty when `daily` is
            /// (the mirrored `Bundle` drops it to stay small).
            public let series: [Double]
        }

        public struct Group: Identifiable, Equatable, Sendable {
            public let id: String   // the section title
            public let tiles: [Tile]
        }

        public static func groups(_ s: Stats.Summary) -> [Group] {
            [
                Group(id: "Throughput", tiles: [
                    tile("Commits", s, \.commits),
                    tile("Lines +", s, \.linesAdded),
                    tile("Lines −", s, \.linesRemoved),
                    tile("PRs opened", s, \.prsOpened),
                    tile("PRs merged", s, \.prsMerged),
                    tile("Turns", s, \.turns),
                    tile("Tool calls", s, \.totalToolCalls),
                    tile("Output tokens", s, \.outputTokens),
                ]),
                Group(id: "Messages & sessions", tiles: [
                    tile("Keyboard", s, \.humanMessages),
                    tile("Phone", s, \.phoneMessages),
                    tile("Agents", s, \.agentMessages),
                    tile("Nudges", s, \.nudges),
                    tile("Sessions", s, \.sessionCount),
                    tile("Sub-agents", s, \.subagents),
                ]),
                Group(id: "Autonomy", tiles: [
                    ratio("Messages / commit", s, \.messagesPerCommit),
                    ratio("Tool calls / message", s, \.toolCallsPerHumanMessage),
                    tile("Longest unattended", s, \.longestUnattended, unit: "tool calls"),
                    percent("Human share", s, \.humanShare),
                ]),
                Group(id: "Friction", tiles: [
                    minutes("Waiting on you", s, \.waitingSeconds),
                    tile("Questions", s, \.questions),
                    tile("Denied tools", s, \.denials),
                    tile("Tool errors", s, \.toolErrors),
                    tile("API retries", s, \.retries),
                    tile("Compactions", s, \.compactions),
                ]),
                Group(id: "Limits", tiles: [
                    tile("Switches", s, \.switches),
                    tile("Accounts hit a limit", s, \.limitStops),
                    tile("Revivals", s, \.revivals),
                    tile("Minutes lost, all out", s, \.minutesLostToLimits, format: { Int($0).formatted() }),
                    tile("Ignites", s, \.ignites),
                    tile("Resumes", s, \.resumes),
                ]),
                Group(id: "Cost (API-equivalent estimate)", tiles: [
                    money("Spend", s, \.usd),
                    money("Per commit", s, \.usdPerCommit),
                    money("Per PR", s, \.usdPerPR),
                    ratio("Tokens / line", s, \.tokensPerLine),
                    ratio("Mean hours to merge", s, \.meanMergeHours),
                ]),
            ]
        }

        /// The four session-length buckets, in `Stats.Day.sessionBucket`
        /// order (`< 15 min`, `15–60 min`, `1–4 h`, `> 4 h`).
        public static func sessionLengthRows(_ s: Stats.Summary) -> [(label: String, count: Int)] {
            let labels = ["< 15 min", "15–60 min", "1–4 h", "> 4 h"]
            return Array(zip(labels, s.total.sessionBuckets))
        }

        public static func sessionTimeLine(_ s: Stats.Summary) -> String {
            let total = s.total.sessionSeconds
            let n = max(1, s.total.sessionCount)
            return "\(Int(total / 3600)) h total · \(Int(total / Double(n) / 60)) min per session"
        }

        // MARK: tile builders (verbatim from the Mac pane, 2026-09-04)

        private static func tile(_ name: String, _ s: Stats.Summary, _ key: KeyPath<Stats.Day, Int>,
                                 unit: String? = nil) -> Tile {
            let v = s.total[keyPath: key], p = s.previous[keyPath: key]
            return Tile(id: name, value: v.formatted() + (unit.map { " \($0)" } ?? ""),
                       delta: deltaText(Double(v), Double(p)),
                       series: s.daily.map { Double($0.day[keyPath: key]) })
        }

        private static func tile(_ name: String, _ s: Stats.Summary, _ key: KeyPath<Stats.Day, Double>,
                                 format: @escaping (Double) -> String) -> Tile {
            let v = s.total[keyPath: key], p = s.previous[keyPath: key]
            return Tile(id: name, value: format(v), delta: deltaText(v, p), series: s.daily.map { $0.day[keyPath: key] })
        }

        private static func ratio(_ name: String, _ s: Stats.Summary, _ key: KeyPath<Stats.Day, Double?>) -> Tile {
            Tile(id: name, value: s.total[keyPath: key].map { String(format: "%.1f", $0) } ?? "—",
                delta: zip2(s.total[keyPath: key], s.previous[keyPath: key]).map { deltaText($0, $1) } ?? nil,
                series: s.daily.map { $0.day[keyPath: key] ?? 0 })
        }

        private static func percent(_ name: String, _ s: Stats.Summary, _ key: KeyPath<Stats.Day, Double?>) -> Tile {
            Tile(id: name, value: s.total[keyPath: key].map { "\(Int($0 * 100))%" } ?? "—", delta: nil,
                series: s.daily.map { ($0.day[keyPath: key] ?? 0) * 100 })
        }

        private static func minutes(_ name: String, _ s: Stats.Summary, _ key: KeyPath<Stats.Day, Double>) -> Tile {
            tile(name, s, key) { secs in
                let m = Int(secs / 60)
                return m >= 120 ? "\(m / 60) h \(m % 60) m" : "\(m) min"
            }
        }

        private static func money(_ name: String, _ s: Stats.Summary, _ key: KeyPath<Stats.Day, Double>) -> Tile {
            tile(name, s, key) { "$" + String(format: $0 >= 100 ? "%.0f" : "%.2f", $0) }
        }

        private static func money(_ name: String, _ s: Stats.Summary, _ key: KeyPath<Stats.Day, Double?>) -> Tile {
            Tile(id: name, value: s.total[keyPath: key].map { "$" + String(format: "%.2f", $0) } ?? "—", delta: nil,
                series: s.daily.map { $0.day[keyPath: key] ?? 0 })
        }

        private static func deltaText(_ v: Double, _ p: Double) -> String? {
            guard p != 0 else { return v == 0 ? nil : "new" }
            let pct = Int(((v - p) / p * 100).rounded())
            return pct == 0 ? "±0%" : pct > 0 ? "+\(pct)%" : "−\(-pct)%"
        }

        private static func zip2<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
            guard let a, let b else { return nil }
            return (a, b)
        }
    }
}
