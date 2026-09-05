import Foundation

/// The plaintext documents a member publishes (spec §7, §4.3). Each
/// carries `schema` so a reader can skip a version it does not know;
/// the envelope's `kind` names which of these is inside. Engine ids and
/// account names are opaque strings (no engine leaks its shape here).
public enum TeamDocs {
    /// `days/<yyyy-mm-dd>.json` — one day's `Stats.Day` (Stats v2 shape).
    public struct DayDoc: Codable, Equatable, Sendable {
        public var schema = 1
        public var day: String
        public var stats: Stats.Day
        public init(day: String, stats: Stats.Day) { self.day = day; self.stats = stats }
    }

    public struct Window: Codable, Equatable, Sendable {
        public var label: String
        public var pct: Int
        public var resetsAt: Int?
        public init(label: String, pct: Int, resetsAt: Int? = nil) { self.label = label; self.pct = pct; self.resetsAt = resetsAt }
    }

    /// One fleet's health as the app sees it: the active account and
    /// its usage windows. The CLI, which has no fleet view, sends none.
    public struct Fleet: Codable, Equatable, Sendable {
        public var engine: String
        public var account: String?
        public var windows: [Window]
        public init(engine: String, account: String?, windows: [Window] = []) {
            self.engine = engine; self.account = account; self.windows = windows
        }
    }

    public struct LiveSession: Codable, Equatable, Sendable {
        public var id: String
        /// Project directory basename, never the path.
        public var project: String
        public var status: String
        public var name: String?
        public init(id: String, project: String, status: String, name: String? = nil) {
            self.id = id; self.project = project; self.status = status; self.name = name
        }
    }

    /// `now.json` — live state; deleted on quit.
    public struct Now: Codable, Equatable, Sendable {
        public var schema = 1
        public var at: Int
        public var sessions: [LiveSession]
        public var fleets: [Fleet]
        public var blockers: [String]
        public var crashesToday: Int
        /// The audience hint a leader copies into the roster (§5).
        public var sharesTo: [String: TeamRoster.ShareTarget]
        public init(at: Int, sessions: [LiveSession], fleets: [Fleet], blockers: [String], crashesToday: Int,
                    sharesTo: [String: TeamRoster.ShareTarget]) {
            self.at = at; self.sessions = sessions; self.fleets = fleets; self.blockers = blockers
            self.crashesToday = crashesToday; self.sharesTo = sharesTo
        }
    }

    /// One session in `sessions/index.json`, summed over its transcript
    /// and its sub-agents' transcripts.
    public struct SessionRow: Codable, Equatable, Sendable {
        public var id: String
        public var project: String
        public var name: String?
        public var engine: String
        public var startedAt = 0
        public var endedAt = 0
        /// Minutes the assistant was working (stretch seconds).
        public var busyMinutes = 0
        /// Minutes a finished turn waited for the person.
        public var waitingMinutes = 0
        /// Minutes per `Stats.Activity` raw value.
        public var activities: [String: Int] = [:]
        public var usd = 0.0
        public var subagents = 0
        public init(id: String, project: String, engine: String) { self.id = id; self.project = project; self.engine = engine }
    }

    public struct SessionsIndex: Codable, Equatable, Sendable {
        public var schema = 1
        public var at: Int
        public var sessions: [SessionRow]
        public var fleets: [Fleet]
        public init(at: Int, sessions: [SessionRow], fleets: [Fleet]) { self.at = at; self.sessions = sessions; self.fleets = fleets }
    }

    /// `crashes.json` — `CrashReport.summary` lines, never the raw report.
    public struct Crashes: Codable, Equatable, Sendable {
        public var schema = 1
        public var crashes: [String]
        public init(crashes: [String]) { self.crashes = crashes }
    }
}
