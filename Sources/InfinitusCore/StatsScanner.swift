import Foundation

/// Claude Code transcripts → `Stats.Day`s. `ingest` is the pure per-entry
/// step; `scan` (Task 3) walks the files with a byte-offset cache the way
/// `TokenRateScanner` does. Nothing is summarized — every count is a
/// field Claude Code already writes.
public enum StatsScanner {
    public enum UserKind: Equatable {
        case human, phone, agent, nudge, compaction, toolResult, machinery
    }

    /// Carry-over between appended chunks of one transcript.
    public struct ScanState: Codable, Equatable, Sendable {
        public var lastMessageID: String?
        /// Turn end (final assistant text / a question) awaiting the next
        /// human or phone message — the "waiting on you" clock.
        public var turnEndedAt: Double?
        public var toolsSinceHuman = 0
        /// Per day: first and last entry instants, for session seconds.
        public var firstAt: [String: Double] = [:]
        public var lastAt: [String: Double] = [:]
        public init() {}
    }

    public struct FileEntry: Codable, Equatable, Sendable {
        public var size = 0
        public var offset = 0
        public var cwd: String?
        public var days: [String: Stats.Day] = [:]
        public var state = ScanState()
        public init() {}
    }

    static let waitingCap = 8.0 * 3600

    public static func classifyUser(_ obj: [String: Any]) -> UserKind {
        if (obj["isCompactSummary"] as? Bool) == true { return .compaction }
        guard let message = obj["message"] as? [String: Any] else { return .machinery }
        var text: String?
        if let s = message["content"] as? String {
            text = s
        } else if let blocks = message["content"] as? [[String: Any]] {
            if blocks.contains(where: { ($0["type"] as? String) == "tool_result" }) { return .toolResult }
            if let t = blocks.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String {
                text = t
            } else if blocks.contains(where: { ($0["type"] as? String) == "image" }) {
                text = "[image]"
            }
        }
        guard let raw = text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return .machinery }
        if let origin = obj["origin"] as? [String: Any], let kind = origin["kind"] as? String {
            switch kind {
            case "human": return .human
            case "peer":
                let from = origin["from"] as? String ?? ""
                return peerKind(fromApp: from.contains("/tmp/infinitus-"), body: wrappedBody(raw))
            default: return .machinery   // task-notification, auto-continuation, …
            }
        }
        // Older transcripts: no origin. The text decides.
        guard raw.first == "<" else { return .human }
        guard raw.hasPrefix("<cross-session-message") else { return .machinery }
        let fromApp: Bool = {
            guard let r = raw.range(of: "from-name=\""), let q = raw[r.upperBound...].firstIndex(of: "\"") else { return false }
            return raw[r.upperBound..<q] == "Infinitus"
        }()
        return peerKind(fromApp: fromApp, body: wrappedBody(raw))
    }

    private static func peerKind(fromApp: Bool, body: String) -> UserKind {
        guard fromApp else { return .agent }
        return body.hasPrefix("[Infinitus]") ? .nudge : .phone
    }

    /// The text inside a `<cross-session-message …>` wrapper (or the text itself).
    static func wrappedBody(_ raw: String) -> String {
        guard raw.hasPrefix("<cross-session-message"), let end = raw.firstIndex(of: ">") else { return raw }
        var body = String(raw[raw.index(after: end)...])
        if let close = body.range(of: "</cross-session-message>") { body = String(body[..<close.lowerBound]) }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func ingest(_ obj: [String: Any], sessionID: String, into entry: inout FileEntry,
                              calendar: Calendar = .current) {
        guard let type = obj["type"] as? String, type == "user" || type == "assistant",
              let stamp = obj["timestamp"] as? String, let t = TokenRateScanner.parseStamp(stamp) else { return }
        if entry.cwd == nil, let cwd = obj["cwd"] as? String, !cwd.isEmpty { entry.cwd = cwd }
        let date = Date(timeIntervalSince1970: t)
        let key = Stats.dayKey(date, calendar: calendar)
        var day = entry.days[key] ?? Stats.Day()
        day.sessions.insert(sessionID)
        day.hours[Stats.hourSlot(date, calendar: calendar)] += 1
        if entry.state.firstAt[key] == nil { entry.state.firstAt[key] = t }
        entry.state.lastAt[key] = t
        day.sessionSeconds = entry.state.lastAt[key]! - entry.state.firstAt[key]!

        if type == "user" {
            if obj["toolDenialKind"] != nil { day.denials += 1 }
            let kind = classifyUser(obj)
            switch kind {
            case .human, .phone:
                if kind == .human { day.humanMessages += 1 } else { day.phoneMessages += 1 }
                if let ended = entry.state.turnEndedAt {
                    day.waitingSeconds += min(waitingCap, max(0, t - ended))
                    entry.state.turnEndedAt = nil
                }
                day.longestUnattended = max(day.longestUnattended, entry.state.toolsSinceHuman)
                entry.state.toolsSinceHuman = 0
            case .agent: day.agentMessages += 1
            case .nudge: day.nudges += 1
            case .compaction: day.compactions += 1
            case .toolResult:
                if let blocks = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] {
                    day.toolErrors += blocks.filter { ($0["is_error"] as? Bool) == true }.count
                }
            case .machinery: break
            }
        } else {
            if (obj["isApiErrorMessage"] as? Bool) == true { day.retries += 1 }
            if let message = obj["message"] as? [String: Any] {
                let id = message["id"] as? String
                let model = message["model"] as? String ?? ""
                if let usage = message["usage"] as? [String: Any], !model.hasPrefix("<"),
                   id == nil || id != entry.state.lastMessageID {
                    let input = usage["input_tokens"] as? Int ?? 0
                    let output = usage["output_tokens"] as? Int ?? 0
                    let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
                    let cacheWrite = usage["cache_creation_input_tokens"] as? Int ?? 0
                    day.inputTokens += input
                    day.outputTokens += output
                    if let p = StaticPriceTable.price(model: model) {
                        day.usd += (Double(input) * p.input + Double(output) * p.output
                            + Double(cacheRead) * p.cacheRead + Double(cacheWrite) * p.cacheWrite) / 1_000_000
                    }
                }
                if let id { entry.state.lastMessageID = id }
                if let blocks = message["content"] as? [[String: Any]] {
                    var sawText = false
                    for block in blocks {
                        switch block["type"] as? String {
                        case "tool_use":
                            let name = block["name"] as? String ?? "?"
                            day.toolCalls[name, default: 0] += 1
                            entry.state.toolsSinceHuman += 1
                            if name == "Agent" { day.subagents += 1 }
                            if name == "AskUserQuestion" {
                                day.questions += 1
                                if entry.state.turnEndedAt == nil { day.turns += 1 }
                                entry.state.turnEndedAt = t
                            }
                        case "text": sawText = true
                        default: break
                        }
                    }
                    // A text block with no tool call beside it ends the turn:
                    // the next thing the transcript needs is a person.
                    if sawText, !blocks.contains(where: { ($0["type"] as? String) == "tool_use" }),
                       !model.hasPrefix("<") {
                        if entry.state.turnEndedAt == nil { day.turns += 1 }
                        entry.state.turnEndedAt = t
                    }
                }
            }
        }
        entry.days[key] = day
    }

    public struct Result: Sendable {
        public var days: [String: Stats.Day] = [:]
        public var cwds: Set<String> = []
        public var files = 0
    }

    struct Cache: Codable {
        var version = 1
        var files: [String: FileEntry] = [:]
    }

    public static func defaultCacheURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Infinitus/stats/transcripts.json")
    }

    /// Every `*.jsonl` under `projectsDir` (one directory per project),
    /// parsed from each file's byte watermark. Files untouched for
    /// `maxAge` are skipped. The cache keeps only files that still exist.
    public static func scan(projectsDir: URL, cacheURL: URL?, calendar: Calendar = .current,
                            maxAge: TimeInterval = 400 * 86_400, now: Date = Date()) -> Result {
        var cache = cacheURL.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(Cache.self, from: $0) } ?? Cache()
        if cache.version != 1 { cache = Cache() }
        var live: [String: FileEntry] = [:]
        var result = Result()
        let fm = FileManager.default
        for project in (try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil)) ?? [] {
            for url in (try? fm.contentsOfDirectory(at: project, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
            where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                      let size = values.fileSize else { continue }
                if let mtime = values.contentModificationDate, now.timeIntervalSince(mtime) > maxAge { continue }
                var entry = cache.files[url.path] ?? FileEntry()
                if size < entry.size { entry = FileEntry() }
                if size != entry.size {
                    parse(url: url, sessionID: url.deletingPathExtension().lastPathComponent,
                          into: &entry, calendar: calendar)
                    entry.size = size
                }
                live[url.path] = entry
                result.files += 1
                if let cwd = entry.cwd { result.cwds.insert(cwd) }
                for (key, day) in entry.days { result.days[key] = (result.days[key] ?? Stats.Day()) + day }
            }
        }
        cache.files = live
        if let cacheURL, let data = try? JSONEncoder().encode(cache) {
            try? fm.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheURL, options: .atomic)
        }
        return result
    }

    static func parse(url: URL, sessionID: String, into entry: inout FileEntry, calendar: Calendar) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(entry.offset))) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty else { return }
        let newline = UInt8(ascii: "\n")
        guard let lastNewline = data.lastIndex(of: newline) else { return }
        let complete = data[data.startIndex...lastNewline]
        var lineStart = complete.startIndex
        while lineStart < complete.endIndex {
            let lineEnd = complete[lineStart...].firstIndex(of: newline) ?? complete.endIndex
            let line = complete[lineStart..<lineEnd]
            lineStart = lineEnd + 1
            // Cheap pre-filter: only user/assistant entries matter.
            guard line.range(of: Data("\"type\":\"user\"".utf8)) != nil
                    || line.range(of: Data("\"type\":\"assistant\"".utf8)) != nil,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            ingest(obj, sessionID: sessionID, into: &entry, calendar: calendar)
        }
        entry.offset += complete.count
    }
}
