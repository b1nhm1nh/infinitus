import Foundation

/// One entry in a session's read-only feed (#17 layer 1): the phone's
/// chat-style view of a live session's transcript, built the same
/// zero-token way as `SessionProgress` — no summarizing, just picking
/// out what already matters.
public struct SessionFeedItem: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case user, assistant, tool, question, permission, result, limit
    }

    public let kind: Kind
    public let text: String
    public let at: Date?
    /// Set only for `.tool`/`.permission` items.
    public let toolName: String?
    /// Set only for `.question` items — the option labels, read-only.
    public let options: [String]?

    public init(kind: Kind, text: String, at: Date? = nil, toolName: String? = nil,
                options: [String]? = nil) {
        self.kind = kind
        self.text = text
        self.at = at
        self.toolName = toolName
        self.options = options
    }
}

/// The feed for one live session, as served by `GET /sessions/<pid>/tail`.
public struct SessionFeed: Codable, Sendable {
    public let pid: Int32
    public let sessionId: String
    public let cwd: String
    public let status: String?
    public let waiting: Bool
    public let items: [SessionFeedItem]

    public init(pid: Int32, sessionId: String, cwd: String, status: String?,
                waiting: Bool, items: [SessionFeedItem]) {
        self.pid = pid
        self.sessionId = sessionId
        self.cwd = cwd
        self.status = status
        self.waiting = waiting
        self.items = items
    }
}

public enum SessionFeedReader {
    /// Same tail-read convention as `Transcript`/`SessionProgress`, sized
    /// for how far back "recent important messages" needs to look rather
    /// than a full limit-stop check.
    static let tailBytes = 256 * 1024
    /// Assistant AND user text items are capped here — the sessions this
    /// serves are dispatch-driven, so user prompts run multi-KB too, and
    /// this feed is polled every 5s from the phone.
    static let textCap = 400

    /// Reads `~/.claude/projects/<slug>/<sessionId>.jsonl` for the given
    /// record and parses its tail. `nil` only when the record carries no
    /// session id at all (nothing to read) — a transcript that's missing
    /// or unreadable still yields a `SessionFeed` with empty `items`,
    /// same "degrade, never throw" convention as `Transcript`.
    public static func read(record: ClaudeSessionRecord, claudeDir: URL,
                             limit: Int = 30) -> SessionFeed? {
        guard !record.sessionId.isEmpty else { return nil }
        let url = Transcript.path(cwd: record.cwd, sessionId: record.sessionId, claudeDir: claudeDir)
        let lines = tail(of: url, maxBytes: tailBytes)
        let raw = parse(lines: lines, limit: limit)
        let (items, waiting) = finalize(items: raw, status: record.status)
        return SessionFeed(pid: record.pid, sessionId: record.sessionId, cwd: record.cwd,
                           status: record.status, waiting: waiting, items: items)
    }

    private static func tail(of url: URL, maxBytes: Int) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let blob = try? handle.readToEnd() else { return [] }
        return blob.split(separator: UInt8(ascii: "\n")).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The record-level finishing touch `read` applies after `parse`,
    /// factored out so it's testable without touching disk: a tool call
    /// still open when the record says "waiting" is a permission prompt,
    /// not just a tool in flight.
    public static func finalize(items: [SessionFeedItem], status: String?)
        -> (items: [SessionFeedItem], waiting: Bool) {
        var items = items
        if status == "waiting", let last = items.last, last.kind == .tool {
            items[items.count - 1] = SessionFeedItem(kind: .permission, text: last.text,
                                                      at: last.at, toolName: last.toolName)
        }
        let waiting = status == "waiting"
            || (items.last.map { $0.kind == .question || $0.kind == .permission } ?? false)
        return (items, waiting)
    }

    /// Parses a tail of JSONL lines (oldest→newest) into feed items,
    /// tolerant of a torn first line — same convention as
    /// `SessionProgress.parse`. Returns at most `limit` items, newest
    /// last.
    public static func parse(lines: [String], limit: Int) -> [SessionFeedItem] {
        let entries: [[String: Any]] = lines.compactMap { line in
            guard line.first == "{",
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return obj
        }

        /// A run of consecutive `.tool` items — any tools (user 2026-09-03:
        /// "all the tool uses should be combined into one") — collapsed
        /// into one chip showing the latest call, the count and the mix of
        /// tool names. An error result never merges into or over one, so
        /// it stays visible rather than being swallowed by "(×N)".
        struct Run {
            var item: SessionFeedItem
            var count: Int
            var isError: Bool
            /// Distinct tool names in first-seen order.
            var names: [String] = []
        }
        var runs: [Run] = []
        var toolNames: [String: String] = [:]   // tool_use id -> name

        func timestamp(_ entry: [String: Any]) -> Date? {
            (entry["timestamp"] as? String).flatMap(UsageHistory.parseISO)
        }

        func append(_ item: SessionFeedItem, isError: Bool = false) {
            if item.kind == .tool, !isError, let last = runs.last, !last.isError,
               last.item.kind == .tool {
                var names = last.names
                if let name = item.toolName, !names.contains(name) { names.append(name) }
                runs[runs.count - 1] = Run(item: item, count: last.count + 1, isError: false,
                                           names: names)
            } else {
                runs.append(Run(item: item, count: 1, isError: isError,
                                names: item.toolName.map { [$0] } ?? []))
            }
        }

        /// Trimmed first-line-or-whole text of a "real" user prompt
        /// entry — nil for a tool_result-only entry or a system-injected
        /// payload (`<command-name>`, `<system-reminder>`, …).
        func realUserText(_ entry: [String: Any]) -> String? {
            guard (entry["type"] as? String) == "user",
                  let message = entry["message"] as? [String: Any] else { return nil }
            let text: String?
            if let plain = message["content"] as? String {
                text = plain
            } else if let content = message["content"] as? [[String: Any]] {
                text = content.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String
            } else {
                text = nil
            }
            guard let text else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.first != "<" else { return nil }
            return trimmed
        }

        /// Whether an assistant text block at `index` is the final answer
        /// of its turn: the next `user`/`assistant` entry (bookkeeping
        /// entries like `turn_duration` skipped) is either absent or a
        /// real user prompt. Anything else (another assistant entry, or a
        /// user entry that's only a tool_result) means more of the same
        /// turn is still coming.
        func isTurnEnd(_ index: Int) -> Bool {
            var i = index + 1
            while i < entries.count {
                let type = entries[i]["type"] as? String
                if type == "assistant" { return false }
                if type == "user" { return realUserText(entries[i]) != nil }
                i += 1
            }
            return true
        }

        for (index, entry) in entries.enumerated() {
            let type = entry["type"] as? String
            if type == "user" {
                if let text = realUserText(entry) {
                    append(SessionFeedItem(kind: .user, text: String(text.prefix(textCap)),
                                           at: timestamp(entry)))
                    continue
                }
                guard let message = entry["message"] as? [String: Any],
                      let content = message["content"] as? [[String: Any]] else { continue }
                for block in content where (block["type"] as? String) == "tool_result" {
                    guard (block["is_error"] as? Bool) == true else { continue }
                    let name = toolNames[block["tool_use_id"] as? String ?? ""]
                    append(SessionFeedItem(kind: .tool, text: "error: \(errorSummary(block))",
                                           at: timestamp(entry), toolName: name), isError: true)
                }
                continue
            }
            guard type == "assistant" else { continue }
            if Transcript.isLimitStop(entry) {
                append(SessionFeedItem(kind: .limit, text: Transcript.limitText(entry),
                                       at: timestamp(entry)))
                continue
            }
            guard let message = entry["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            for block in content {
                switch block["type"] as? String {
                case "text":
                    guard let text = block["text"] as? String else { continue }
                    let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(textCap))
                    guard !trimmed.isEmpty else { continue }
                    let kind: SessionFeedItem.Kind = isTurnEnd(index) ? .result : .assistant
                    append(SessionFeedItem(kind: kind, text: trimmed, at: timestamp(entry)))
                case "tool_use":
                    let name = block["name"] as? String ?? ""
                    if let id = block["id"] as? String { toolNames[id] = name }
                    if name == "AskUserQuestion" {
                        let (question, options) = describeQuestion(block)
                        append(SessionFeedItem(kind: .question, text: question,
                                               at: timestamp(entry), options: options))
                    } else {
                        let summary = describeTool(name: name, input: block["input"] as? [String: Any] ?? [:])
                        append(SessionFeedItem(kind: .tool, text: summary,
                                               at: timestamp(entry), toolName: name))
                    }
                default:
                    continue
                }
            }
        }

        let items = runs.map { run -> SessionFeedItem in
            guard run.count > 1 else { return run.item }
            // A mixed run names every tool it covers, latest call as the text.
            let toolName = run.names.count > 1 ? run.names.joined(separator: ", ") : run.item.toolName
            return SessionFeedItem(kind: run.item.kind, text: "\(run.item.text) (\u{00d7}\(run.count))",
                                   at: run.item.at, toolName: toolName, options: run.item.options)
        }
        return Array(items.suffix(max(0, limit)))
    }

    private static func errorSummary(_ block: [String: Any]) -> String {
        if let text = block["content"] as? String { return String(text.prefix(200)) }
        if let parts = block["content"] as? [[String: Any]],
           let text = parts.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String {
            return String(text.prefix(200))
        }
        return "tool error"
    }

    private static func describeQuestion(_ block: [String: Any]) -> (String, [String]) {
        guard let input = block["input"] as? [String: Any],
              let questions = input["questions"] as? [[String: Any]], !questions.isEmpty
        else { return ("", []) }
        let text = questions.compactMap { $0["question"] as? String }.joined(separator: "\n")
        let options = questions.flatMap { question -> [String] in
            (question["options"] as? [[String: Any]])?.compactMap { $0["label"] as? String } ?? []
        }
        return (text, options)
    }

    /// One-line summary of a tool call's input — the Bash command or the
    /// file path, same signals `SessionProgress.describe` reads, just
    /// without the verb prefix (the tool name carries that on the phone).
    private static func describeTool(name: String, input: [String: Any]) -> String {
        switch name {
        case "Bash":
            let command = (input["command"] as? String ?? "").replacingOccurrences(of: "\n", with: " ")
            return String(command.prefix(120))
        case "Read", "Edit", "Write":
            let path = input["file_path"] as? String ?? ""
            return URL(fileURLWithPath: path).lastPathComponent
        case "Grep":
            return String((input["pattern"] as? String ?? "").prefix(60))
        default:
            return ""
        }
    }
}
