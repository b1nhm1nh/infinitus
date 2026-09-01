import Foundation

/// Zero-token progress snapshot derived from a transcript tail — "layer 0"
/// from docs/research/session-progress.md: what the transcript already
/// says about a session, without spending a single token to summarize it.
public struct SessionProgress: Sendable, Equatable {
    /// The most recent `TodoWrite` payload — a structured self-report the
    /// agent already maintains, read for free.
    public struct Todos: Sendable, Equatable {
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
    /// Sum of `message.usage.output_tokens` across the tail.
    public let outputTokens: Int
    /// True when the last entry that decides whether work has stopped
    /// (Transcript's notion) is an assistant API-error message.
    public let retrying: Bool

    public init(lastActivityAt: Date? = nil, nowDoing: String? = nil, todos: Todos? = nil,
                title: String? = nil, outputTokens: Int = 0, retrying: Bool = false) {
        self.lastActivityAt = lastActivityAt
        self.nowDoing = nowDoing
        self.todos = todos
        self.title = title
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
                                title: title, outputTokens: outputTokens, retrying: retrying)
    }

    /// Reads the tail of `<claudeDir>/projects/<slug>/<sessionId>.jsonl`
    /// (same path and tail-read approach as `Transcript.lastTurnEntry`)
    /// and parses it.
    public static func read(sessionId: String, cwd: String, claudeDir: URL,
                             maxBytes: Int = 512 * 1024) -> SessionProgress {
        let url = Transcript.path(cwd: cwd, sessionId: sessionId, claudeDir: claudeDir)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return parse(lines: []) }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return parse(lines: []) }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let blob = try? handle.readToEnd() else { return parse(lines: []) }
        let lines = blob.split(separator: UInt8(ascii: "\n"))
            .map { String(decoding: $0, as: UTF8.self) }
        return parse(lines: lines)
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
            let first = command.split(separator: " ", maxSplits: 1).first.map(String.init) ?? command
            return "Running \(first)"
        case "Grep":
            let pattern = input["pattern"] as? String ?? ""
            return "Searching \(pattern.prefix(40))"
        default:
            return name
        }
    }
}
