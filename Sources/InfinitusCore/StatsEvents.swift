import Foundation

/// One line of the app's durable event log (`events.jsonl`) — what the
/// Activity pane shows, kept so Stats can count switches and limits
/// over months.
public struct StatsEvent: Codable, Equatable, Sendable {
    public let at: Date
    public let kind: String
    public let icon: String
    public let text: String
    public init(at: Date, kind: String, icon: String, text: String) {
        self.at = at; self.kind = kind; self.icon = icon; self.text = text
    }
}

public enum StatsEvents {
    public static func days(_ events: [StatsEvent], calendar: Calendar = .current) -> [String: Stats.Day] {
        var days: [String: Stats.Day] = [:]
        var allOutSince: Date?
        for e in events.sorted(by: { $0.at < $1.at }) {
            let key = Stats.dayKey(e.at, calendar: calendar)
            var d = days[key] ?? Stats.Day()
            switch e.kind {
            case "switch": d.switches += 1
            case "death": d.limitStops += 1
            case "limit": if allOutSince == nil { allOutSince = e.at }
            case "revival":
                d.revivals += 1
                if let since = allOutSince {
                    d.minutesLostToLimits += e.at.timeIntervalSince(since) / 60
                    allOutSince = nil
                }
            case "ignite": d.ignites += 1
            case "resume", "nudge": d.resumes += 1
            default: break
            }
            days[key] = d
        }
        return days
    }
}
