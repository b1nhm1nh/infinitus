import Foundation

/// Stats v2 (issue #24): a transcript is a run of *stretches* — what the
/// assistant did between two of the person's messages — and each one is
/// labeled by its strongest signal. `StatsScanner.ingest` feeds the open
/// stretch; `Stats.Day.add(stretch:)` folds a closed one in. Every rule
/// here is a heuristic and is presented as one.
extension StatsScanner {
    public struct Stretch: Codable, Equatable, Sendable {
        /// The day the opening message landed on — the stretch is
        /// charged there even when it runs past midnight.
        public var dayKey: String
        public var startedAt: Double
        public var lastAt: Double
        /// Assistant entries seen. A stretch that never got one (a burst
        /// of peer messages, the session's last unanswered prompt) is not
        /// effort — `Day.add(stretch:)` skips it so "Other" stays honest.
        public var entries = 0
        /// The first rule-1 vote (`Stats.Activity.rawValue`); nil until
        /// a skill / sub-agent / tool says something.
        public var label: String?
        public var edits = 0
        public var testEdits = 0
        public var bash = 0
        /// The last assistant entry was prose with no tool call beside it.
        public var endedInProse = false
        /// The model of the last usage-bearing entry; "" before one.
        public var model = ""
        public var inputTokens = 0
        public var outputTokens = 0
        public var usd = 0.0

        public init(dayKey: String, at t: Double) {
            self.dayKey = dayKey
            startedAt = t
            lastAt = t
        }

        /// Spec rules, first match wins: a rule-1 label; every edit a
        /// test file → tests, a mix → code; no edits and no commands
        /// but a prose ending → explanation; something ran → code;
        /// nothing at all (a read-only stretch cut short) → other.
        public var activity: Stats.Activity {
            if let label, let a = Stats.Activity(rawValue: label) { return a }
            if edits > 0 { return testEdits == edits ? .tests : .code }
            if bash > 0 { return .code }
            return endedInProse ? .explanation : .other
        }

        public var tally: Stats.ActivityTally {
            var t = Stats.ActivityTally()
            t.stretches = 1
            t.seconds = max(0, lastAt - startedAt)
            t.inputTokens = inputTokens
            t.outputTokens = outputTokens
            t.usd = usd
            return t
        }
    }

    /// Rule 1 of the classifier: what a single tool_use block says the
    /// stretch is about. Substring tests, lowercase, so plugin prefixes
    /// (`pr-review-toolkit:review-pr`) and namespaced skills match.
    public enum ActivitySignals {
        public static func label(tool name: String, input: [String: Any]) -> Stats.Activity? {
            if name.hasPrefix("mcp__claude-in-chrome__") || name.hasPrefix("mcp__playwright") || name == "computer" {
                return .browser
            }
            switch name {
            case "EnterPlanMode", "ExitPlanMode": return .plan
            case "ReportFindings": return .review
            case "Skill":
                let skill = (input["skill"] as? String ?? "").lowercased()
                if skill.contains("review") { return .review }
                if skill.contains("brainstorm") || skill.contains("plan") { return .plan }
                if skill.contains("debug") { return .debug }
                if skill.contains("playwright") || skill.contains("browser") || skill.contains("chrome") { return .browser }
                return nil
            case "Agent":
                let kind = (input["subagent_type"] as? String ?? "").lowercased()
                if kind.contains("review") || kind.contains("analyzer") || kind.contains("hunter") { return .review }
                if kind.contains("plan") || kind.contains("architect") { return .plan }
                return nil
            case "Bash":
                let command = input["command"] as? String ?? ""
                if simulatorMarkers.contains(where: { command.contains($0) }) { return .simulator }
                if reviewCommands.contains(where: { command.contains($0) }) { return .review }
                return nil
            default: return nil
            }
        }

        static let simulatorMarkers = ["xcrun simctl", "simctl ", "platform=iOS Simulator", "devicectl", "adb "]
        static let reviewCommands = ["gh pr review", "gh pr diff"]

        /// The repo conventions the spec names: a `Tests`/`tests`/
        /// `__tests__`/`test`/`spec` directory, or a test-shaped file name.
        public static func isTestPath(_ path: String) -> Bool {
            let parts = path.split(separator: "/").map(String.init)
            guard let file = parts.last else { return false }
            if parts.dropLast().contains(where: { testDirs.contains($0) }) { return true }
            let lower = file.lowercased()
            return file.hasSuffix("Tests.swift") || file.hasSuffix("Test.swift")
                || lower.contains(".test.") || lower.contains(".spec.")
                || lower.hasPrefix("test_") || lower.hasSuffix("_test.go") || lower.hasSuffix("_test.py")
                || lower.hasSuffix("_spec.rb")
        }

        static let testDirs: Set<String> = ["Tests", "tests", "test", "__tests__", "spec"]
    }
}

extension Stats.Day {
    /// Fold a closed stretch in: its whole tally under its activity, and
    /// its stretch count + wall time under its model. The model's
    /// tokens/$ are NOT added here — `ingest` already charged them per
    /// entry (that path also covers sub-agent files, which never form a
    /// stretch).
    public mutating func add(stretch s: StatsScanner.Stretch) {
        guard s.entries > 0 else { return }
        let t = s.tally
        activities[s.activity.rawValue] = (activities[s.activity.rawValue] ?? Stats.ActivityTally()) + t
        guard !s.model.isEmpty else { return }
        var m = byModel[s.model] ?? Stats.ActivityTally()
        m.stretches += 1
        m.seconds += t.seconds
        byModel[s.model] = m
    }
}

extension StatsScanner.FileEntry {
    /// `days` with the still-open stretch charged in — the Result's
    /// form. The cache keeps `days` pure so the next chunk can keep
    /// feeding the stretch and close it exactly once.
    public func daysWithOpenStretch() -> [String: Stats.Day] {
        guard let s = state.stretch else { return days }
        var out = days
        var d = out[s.dayKey] ?? Stats.Day()
        d.add(stretch: s)
        out[s.dayKey] = d
        return out
    }
}
