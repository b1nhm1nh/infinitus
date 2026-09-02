import Foundation

/// Zero-token progress snapshot derived from a transcript tail — "layer 0"
/// from docs/research/session-progress.md: what the transcript already
/// says about a session, without spending a single token to summarize it.
public struct SessionProgress: Sendable, Equatable, Codable {
    /// The most recent `TodoWrite` payload — a structured self-report the
    /// agent already maintains, read for free.
    public struct Todos: Sendable, Equatable, Codable {
        public let done: Int
        public let total: Int
        public let activeForm: String?

        public init(done: Int, total: Int, activeForm: String?) {
            self.done = done
            self.total = total
            self.activeForm = activeForm
        }
    }

    /// Newest entry's own timestamp.
    public let lastActivityAt: Date?
    /// Human line derived from the last signal (tool_use or assistant text).
    public let nowDoing: String?
    /// Latest TodoWrite payload in the tail; nil if none appears.
    public let todos: Todos?
    /// Latest `type:"summary"` entry's `summary` field.
    public let title: String?
    /// What the session was asked to do — the first real user prompt at the
    /// transcript HEAD, not the tail. Nil when the head has no qualifying
    /// entry (or wasn't read). New optional field; absent in old cached
    /// JSON, which still decodes fine.
    public let goal: String?
    /// Layer 1 (docs/research/session-progress.md): "exploring" /
    /// "building" / "verifying" / "wrapping up", inferred from the tool
    /// mix over the tail's last `phaseWindow` classifiable tool calls,
    /// recency-weighted so explore→edit→test drift lands on the latest
    /// phase rather than the tail's plurality. A heuristic — the UI shows
    /// it only when there's no TodoWrite self-report to show instead —
    /// and nil below `phaseMinimumSignals` calls so a fresh session
    /// doesn't read "exploring" off a single Read. New optional field;
    /// absent in old cached JSON, which still decodes fine.
    public let phase: String?
    /// Sum of `message.usage.output_tokens` across the tail.
    public let outputTokens: Int
    /// True when the last entry that decides whether work has stopped
    /// (Transcript's notion) is an assistant API-error message.
    public let retrying: Bool

    public init(lastActivityAt: Date? = nil, nowDoing: String? = nil, todos: Todos? = nil,
                title: String? = nil, goal: String? = nil, phase: String? = nil,
                outputTokens: Int = 0, retrying: Bool = false) {
        self.lastActivityAt = lastActivityAt
        self.nowDoing = nowDoing
        self.todos = todos
        self.title = title
        self.goal = goal
        self.phase = phase
        self.outputTokens = outputTokens
        self.retrying = retrying
    }

    /// Parses a tail of JSONL lines (oldest→newest). Tolerant of a torn
    /// first line — the tail may start mid-object — lines that don't parse
    /// as a JSON object are skipped, never an error, same convention as
    /// Transcript/UsageHistory.
    public static func parse(lines: [String]) -> SessionProgress {
        let entries: [[String: Any]] = lines.compactMap { line in
            guard line.first == "{",
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return obj
        }

        var lastActivityAt: Date?
        for entry in entries.reversed() {
            if let ts = entry["timestamp"] as? String, let date = UsageHistory.parseISO(ts) {
                lastActivityAt = date
                break
            }
        }

        var nowDoing: String?
        for entry in entries.reversed() {
            guard let message = entry["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            if let toolUse = content.first(where: { ($0["type"] as? String) == "tool_use" }) {
                nowDoing = describe(toolUse)
                break
            }
            if let textBlock = content.first(where: { ($0["type"] as? String) == "text" }),
               let text = textBlock["text"] as? String,
               let firstLine = text.split(separator: "\n", maxSplits: 1).first,
               !firstLine.isEmpty {
                nowDoing = String(firstLine.prefix(80))
                break
            }
        }

        var todos: Todos?
        search: for entry in entries.reversed() {
            guard let message = entry["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            for block in content where (block["type"] as? String) == "tool_use"
                && (block["name"] as? String) == "TodoWrite" {
                guard let input = block["input"] as? [String: Any],
                      let items = input["todos"] as? [[String: Any]] else { continue }
                let done = items.filter { ($0["status"] as? String) == "completed" }.count
                let activeForm = items.first { ($0["status"] as? String) == "in_progress" }?["activeForm"] as? String
                todos = Todos(done: done, total: items.count, activeForm: activeForm)
                break search
            }
        }

        var title: String?
        for entry in entries.reversed() where (entry["type"] as? String) == "summary" {
            title = entry["summary"] as? String
            break
        }

        var outputTokens = 0
        for entry in entries {
            if let message = entry["message"] as? [String: Any],
               let usage = message["usage"] as? [String: Any],
               let tokens = usage["output_tokens"] as? Int {
                outputTokens += tokens
            }
        }

        var lastDecisive: [String: Any]?
        for entry in entries.reversed() where Transcript.decidesTheTurn(entry) {
            lastDecisive = entry
            break
        }
        let retrying = (lastDecisive?["type"] as? String) == "assistant"
            && (lastDecisive?["isApiErrorMessage"] as? Bool) == true

        return SessionProgress(lastActivityAt: lastActivityAt, nowDoing: nowDoing, todos: todos,
                                title: title, goal: goal(lines: lines), phase: phase(entries: entries),
                                outputTokens: outputTokens, retrying: retrying)
    }

    static let phaseWindow = 24
    static let phaseMinimumSignals = 4

    /// Later phases win ties, and "wrapping up" is decisive on its own:
    /// commits and pushes are sparse, so one in the last three calls
    /// outranks the weighted mix.
    private enum Phase: Int, Comparable {
        case exploring, building, verifying, wrappingUp
        static func < (a: Phase, b: Phase) -> Bool { a.rawValue < b.rawValue }
        var label: String {
            switch self {
            case .exploring: return "exploring"
            case .building: return "building"
            case .verifying: return "verifying"
            case .wrappingUp: return "wrapping up"
            }
        }
    }

    private static func phase(entries: [[String: Any]]) -> String? {
        var calls: [Phase] = []
        for entry in entries {
            guard let message = entry["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            for block in content where (block["type"] as? String) == "tool_use" {
                if let phase = classify(block) { calls.append(phase) }
            }
        }
        let recent = Array(calls.suffix(phaseWindow))
        guard recent.count >= phaseMinimumSignals else { return nil }
        if recent.suffix(3).contains(.wrappingUp) { return Phase.wrappingUp.label }
        // Half-life of three calls: a lone Read mid-edit doesn't flip the
        // word, three test runs after a run of edits does.
        var score: [Phase: Double] = [:]
        for (i, phase) in recent.enumerated() where phase != .wrappingUp {
            score[phase, default: 0] += pow(2, Double(i + 1 - recent.count) / 3)
        }
        return score.max { ($0.value, $0.key) < ($1.value, $1.key) }?.key.label
    }

    /// Neutral tools (TodoWrite, AskUserQuestion, messaging, unknown Bash)
    /// are uncounted. Edits made through sed/heredocs read as nothing —
    /// accepted; detecting shell edits isn't worth the false positives.
    private static func classify(_ toolUse: [String: Any]) -> Phase? {
        let name = toolUse["name"] as? String ?? ""
        switch name {
        case "Read", "Grep", "Glob", "LS", "WebFetch", "WebSearch", "Agent", "Task":
            return .exploring
        case "Edit", "Write", "MultiEdit", "NotebookEdit":
            return .building
        case "Bash":
            let input = toolUse["input"] as? [String: Any] ?? [:]
            let words = leadWords(input["command"] as? String ?? "")
            guard let head = words.first else { return nil }
            if head == "git", words.dropFirst().first.map({ ["commit", "push"].contains($0) }) == true { return .wrappingUp }
            if head == "gh", words.dropFirst().first == "pr" { return .wrappingUp }
            let runners: Set<String> = ["pytest", "xcodebuild", "make", "ctest", "tsc", "jest", "vitest", "eslint", "swiftlint"]
            if runners.contains(head) { return .verifying }
            let verbs: Set<String> = ["test", "build", "check", "lint", "typecheck"]
            if words.prefix(3).contains(where: verbs.contains) { return .verifying }
            return nil
        default:
            return nil
        }
    }

    /// The first real user prompt at the HEAD of the transcript (oldest→
    /// newest), skipping tool_result entries and system-injected payloads
    /// (`<command-name>`, `<system-reminder>`, etc. — anything starting
    /// with `<`). First line only, leading whitespace stripped, truncated
    /// to 100 chars.
    public static func goal(lines: [String]) -> String? {
        let entries: [[String: Any]] = lines.compactMap { line in
            guard line.first == "{",
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return obj
        }

        for entry in entries where (entry["type"] as? String) == "user" {
            guard let message = entry["message"] as? [String: Any] else { continue }
            let text: String?
            if let plain = message["content"] as? String {
                text = plain
            } else if let content = message["content"] as? [[String: Any]], let first = content.first {
                text = (first["type"] as? String) == "tool_result" ? nil : first["text"] as? String
            } else {
                text = nil
            }
            guard let text, let rawFirstLine = text.split(separator: "\n", maxSplits: 1).first else { continue }
            var firstLine = Substring(rawFirstLine)
            while let head = firstLine.first, head.isWhitespace { firstLine.removeFirst() }
            guard !firstLine.isEmpty, firstLine.first != "<" else { continue }
            return String(firstLine.prefix(100))
        }
        return nil
    }

    /// Reads the tail of `<claudeDir>/projects/<slug>/<sessionId>.jsonl`
    /// (same path and tail-read approach as `Transcript.lastTurnEntry`)
    /// and parses it.
    public static func read(sessionId: String, cwd: String, claudeDir: URL,
                             maxBytes: Int = 512 * 1024) -> SessionProgress {
        let url = Transcript.path(cwd: cwd, sessionId: sessionId, claudeDir: claudeDir)
        let headGoal = readGoal(sessionId: sessionId, cwd: cwd, claudeDir: claudeDir)
        func withGoal(_ progress: SessionProgress) -> SessionProgress {
            SessionProgress(lastActivityAt: progress.lastActivityAt, nowDoing: progress.nowDoing,
                             todos: progress.todos, title: progress.title,
                             goal: headGoal ?? progress.goal, phase: progress.phase,
                             outputTokens: progress.outputTokens, retrying: progress.retrying)
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return withGoal(parse(lines: [])) }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return withGoal(parse(lines: [])) }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let blob = try? handle.readToEnd() else { return withGoal(parse(lines: [])) }
        let lines = blob.split(separator: UInt8(ascii: "\n"))
            .map { String(decoding: $0, as: UTF8.self) }
        return withGoal(parse(lines: lines))
    }

    /// Reads only the FIRST `maxBytes` of the transcript — the goal lives at
    /// the HEAD, the opposite end from everything else `read` extracts.
    public static func readGoal(sessionId: String, cwd: String, claudeDir: URL,
                                 maxBytes: Int = 64 * 1024) -> String? {
        let url = Transcript.path(cwd: cwd, sessionId: sessionId, claudeDir: claudeDir)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let blob = try? handle.read(upToCount: maxBytes) else { return nil }
        let lines = blob.split(separator: UInt8(ascii: "\n"))
            .map { String(decoding: $0, as: UTF8.self) }
        return goal(lines: lines)
    }

    /// Pairs each engine-reported session with its Claude Code session
    /// record by pid; a session with no matching record is dropped — the
    /// popover row falls back to its current single-line rendering.
    public static func match(sessions: [SessionDetail], records: [ClaudeSessionRecord])
        -> [(session: SessionDetail, record: ClaudeSessionRecord)] {
        let byPid = Dictionary(records.map { (Int($0.pid), $0) }, uniquingKeysWith: { a, _ in a })
        return sessions.compactMap { s in byPid[s.pid].map { (s, $0) } }
    }

    /// Words of the first `&&` segment that isn't a cd/env preamble —
    /// compound commands open with plumbing ("cd x && swift build").
    private static func leadWords(_ command: String) -> [String] {
        let plumbing: Set<String> = ["cd", "export", "source", "set"]
        let segments = command.split(separator: "&&")
            .map { $0.split(separator: " ").map(String.init) }
            .filter { !$0.isEmpty }
        return segments.first { !plumbing.contains($0[0]) } ?? segments.first ?? []
    }

    private static func describe(_ toolUse: [String: Any]) -> String {
        let name = toolUse["name"] as? String ?? ""
        let input = toolUse["input"] as? [String: Any] ?? [:]
        switch name {
        case "Read", "Edit", "Write":
            let verb = name == "Read" ? "Reading" : name == "Edit" ? "Editing" : "Writing"
            let path = input["file_path"] as? String ?? ""
            return "\(verb) \(URL(fileURLWithPath: path).lastPathComponent)"
        case "Bash":
            let command = input["command"] as? String ?? ""
            return "Running \(leadWords(command).first ?? command)"
        case "Grep":
            let pattern = input["pattern"] as? String ?? ""
            return "Searching \(pattern.prefix(40))"
        default:
            return name
        }
    }
}

/// Compact per-session row for a fleet panel (the Linux Quickshell panel,
/// issue #13 step 4) — repo name, status, and a one-line progress
/// summary. Pure mapping from a live session record + its
/// transcript-derived progress, so it's testable without touching disk.
public struct SessionPanelRow: Sendable, Equatable, Codable {
    public let repo: String
    public let status: String
    public let nowDoing: String?
    public let todosDone: Int?
    public let todosTotal: Int?
    public let activeForm: String?
    public let retrying: Bool
    public let quietMinutes: Int?
    public let goal: String?
    public let phase: String?

    public init(repo: String, status: String, nowDoing: String? = nil, todosDone: Int? = nil,
                todosTotal: Int? = nil, activeForm: String? = nil, retrying: Bool = false,
                quietMinutes: Int? = nil, goal: String? = nil, phase: String? = nil) {
        self.repo = repo
        self.status = status
        self.nowDoing = nowDoing
        self.todosDone = todosDone
        self.todosTotal = todosTotal
        self.activeForm = activeForm
        self.retrying = retrying
        self.quietMinutes = quietMinutes
        self.goal = goal
        self.phase = phase
    }

    /// `repo` is the last path component of the record's cwd. `quietMinutes`
    /// is present only once the transcript has been silent over 120s — same
    /// threshold as the macOS popover's SessionProgressLine.
    public static func make(record: ClaudeSessionRecord, progress: SessionProgress,
                             now: Date = Date()) -> SessionPanelRow {
        let quietMinutes: Int? = progress.lastActivityAt.flatMap { last in
            let idle = now.timeIntervalSince(last)
            return idle > 120 ? Int(idle / 60) : nil
        }
        return SessionPanelRow(
            repo: URL(fileURLWithPath: record.cwd).lastPathComponent,
            status: record.status ?? "",
            nowDoing: progress.nowDoing,
            todosDone: progress.todos?.done,
            todosTotal: progress.todos?.total,
            activeForm: progress.todos?.activeForm,
            retrying: progress.retrying,
            quietMinutes: quietMinutes,
            goal: progress.goal,
            phase: progress.phase)
    }
}
