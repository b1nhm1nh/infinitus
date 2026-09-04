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
        /// True for `<project>/<session-id>/subagents/agent-*.jsonl` — a
        /// subagent's own transcript. `ingest` gates on this: only
        /// tokens/usd/toolCalls/toolErrors/retries/compactions/subagents
        /// count; everything session/message/turn-shaped is the
        /// PARENT session's business, not this file's (the subagent's
        /// first "user" entry is its prompt FROM the parent, which would
        /// otherwise double as a human message).
        public var subagent = false
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
            let name = raw[r.upperBound..<q]
            return name == "Infinitus" || name == PeerSocket.senderName
        }()
        return peerKind(fromApp: fromApp, body: wrappedBody(raw))
    }

    /// The socket preface's first 48 characters — enough to tell a phone
    /// message from the app's own "[Infinitus] …" nudge text without
    /// retyping the whole preface.
    private static let phoneMarker = String(PeerSocket.phonePreface.prefix(48))

    private static func peerKind(fromApp: Bool, body: String) -> UserKind {
        guard fromApp else { return .agent }
        if body.hasPrefix(phoneMarker) { return .phone }
        if body.hasPrefix("[Infinitus]") { return .nudge }
        return .phone
    }

    /// The text inside a `<cross-session-message …>` wrapper (or the text itself).
    static func wrappedBody(_ raw: String) -> String {
        guard raw.hasPrefix("<cross-session-message"), let end = raw.firstIndex(of: ">") else { return raw }
        var body = String(raw[raw.index(after: end)...])
        if let close = body.range(of: "</cross-session-message>") { body = String(body[..<close.lowerBound]) }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `sessionID`: the parent session id for a subagent file (the
    /// `<session-id>` directory name it lives under) — unused when
    /// `entry.subagent` is true, kept for an honest signature.
    public static func ingest(_ obj: [String: Any], sessionID: String, into entry: inout FileEntry,
                              calendar: Calendar = .current) {
        guard let type = obj["type"] as? String, type == "user" || type == "assistant",
              let stamp = obj["timestamp"] as? String, let t = TokenRateScanner.parseStamp(stamp) else { return }
        if entry.cwd == nil, let cwd = obj["cwd"] as? String, !cwd.isEmpty { entry.cwd = cwd }
        let isSubagent = entry.subagent
        let date = Date(timeIntervalSince1970: t)
        let key = Stats.dayKey(date, calendar: calendar)
        var day = entry.days[key] ?? Stats.Day()
        // A subagent transcript is the parent session's own work under
        // another name — it doesn't add a session, an hour-of-day entry,
        // or its own session-length bucket; only the token/cost/tool
        // facts below are its contribution.
        if !isSubagent {
            day.sessions.insert(sessionID)
            day.hours[Stats.hourSlot(date, calendar: calendar)] += 1
            if entry.state.firstAt[key] == nil { entry.state.firstAt[key] = t }
            entry.state.lastAt[key] = t
            day.sessionSeconds = entry.state.lastAt[key]! - entry.state.firstAt[key]!
            day.sessionBuckets = [0, 0, 0, 0]
            day.sessionBuckets[Stats.Day.sessionBucket(seconds: day.sessionSeconds)] = 1
        }

        if type == "user" {
            if !isSubagent, obj["toolDenialKind"] != nil { day.denials += 1 }
            let kind = classifyUser(obj)
            switch kind {
            case .human, .phone:
                // The trap: a subagent's first "user" entry is its prompt
                // FROM the parent, not a human typing — never a message.
                guard !isSubagent else { break }
                if kind == .human { day.humanMessages += 1 } else { day.phoneMessages += 1 }
                if let ended = entry.state.turnEndedAt {
                    day.waitingSeconds += min(waitingCap, max(0, t - ended))
                    entry.state.turnEndedAt = nil
                }
                day.longestUnattended = max(day.longestUnattended, entry.state.toolsSinceHuman)
                entry.state.toolsSinceHuman = 0
            case .agent: if !isSubagent { day.agentMessages += 1 }
            case .nudge: if !isSubagent { day.nudges += 1 }
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
                            if !isSubagent { entry.state.toolsSinceHuman += 1 }
                            if name == "Agent" { day.subagents += 1 }
                            if name == "AskUserQuestion", !isSubagent {
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
                    // (Never for a subagent file — it has no turns of its own.)
                    if !isSubagent, sawText, !blocks.contains(where: { ($0["type"] as? String) == "tool_use" }),
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
        /// Files that still need a parse after this call (size changed,
        /// budget exhausted before catching them up) — 0 means the corpus
        /// is fully caught up as of this call.
        public var remaining = 0
        /// Bytes still owed across every file counted in `remaining` — 0
        /// once `remaining` is 0.
        public var bytesRemaining = 0
        /// Bytes owed across every dirty file as of the START of this
        /// call, before this call's budget spent any of it — the
        /// denominator for a "scanned X of Y" readout.
        public var bytesTotal = 0
    }

    struct Cache: Codable {
        var version = 2
        var files: [String: FileEntry] = [:]
    }

    public static func defaultCacheURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Infinitus/stats/transcripts.json")
    }

    private static func writeCache(_ cache: Cache, to cacheURL: URL, fm: FileManager) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? fm.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }

    /// Bytes a file still owes given its cached read watermark. A file
    /// that shrank below where we'd already read owes its FULL size (the
    /// scan below resets and re-reads it from zero), not `size - offset`
    /// (which would go negative and clamp to 0 — silently reporting a
    /// file that needs a full re-read as needing nothing at all).
    private static func owed(size: Int, offset: Int) -> Int {
        offset > size ? size : size - offset
    }

    /// Every `*.jsonl` under `projectsDir` (one directory per project),
    /// parsed from each file's byte watermark in bounded windows
    /// (`parse`), newest-modified first. Files untouched for `maxAge`
    /// are skipped. The cache keeps only files that still exist.
    ///
    /// `byteBudget` caps how many bytes get actually READ this call
    /// (nil = unbounded) — files whose size is unchanged cost nothing
    /// and don't count against it. A file only latches its cached `size`
    /// (marking it caught up) once it's been read all the way to the end
    /// — a file the budget ran out partway through stays "dirty" for the
    /// next call, however much of it this call got through. That's what
    /// keeps one huge (654 MB seen in practice) transcript from either
    /// blocking every chunk until it's fully read or getting silently
    /// marked done half-read. `Result.remaining`/`bytesRemaining` say
    /// what's still owed; callers backfilling a large corpus call
    /// repeatedly (newest data first) until `remaining` hits 0. The
    /// cache is written atomically every 200 files touched inside a pass
    /// and once more at the end, so an interrupted backfill loses at
    /// most one checkpoint's worth of work.
    ///
    /// `windowBytes` (default `Self.windowBytes`, 8 MB) exists as a
    /// parameter only so tests can shrink it to exercise multi-window
    /// files deterministically without a multi-MB fixture; every real
    /// caller uses the default.
    public static func scan(projectsDir: URL, cacheURL: URL?, calendar: Calendar = .current,
                            maxAge: TimeInterval = 400 * 86_400, now: Date = Date(),
                            byteBudget: Int? = nil, windowBytes: Int = StatsScanner.windowBytes) -> Result {
        var cache = cacheURL.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(Cache.self, from: $0) } ?? Cache()
        if cache.version != 2 { cache = Cache() }
        let fm = FileManager.default

        // `subagent`: true for `<project>/<session-id>/subagents/*.jsonl`
        // (one fixed depth below a session dir, not a recursive walk).
        // `sessionID`: the file's own transcript id normally, or the
        // PARENT session dir's name for a subagent file.
        struct Candidate { let url: URL; let size: Int; let mtime: Date; let subagent: Bool; let sessionID: String }
        var candidates: [Candidate] = []
        func addCandidate(_ url: URL, subagent: Bool, sessionID: String) {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize else { return }
            let mtime = values.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(mtime) > maxAge { return }
            candidates.append(Candidate(url: url, size: size, mtime: mtime, subagent: subagent, sessionID: sessionID))
        }
        for project in (try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil)) ?? [] {
            for url in (try? fm.contentsOfDirectory(at: project, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey])) ?? [] {
                if url.pathExtension == "jsonl" {
                    addCandidate(url, subagent: false, sessionID: url.deletingPathExtension().lastPathComponent)
                } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    let sessionID = url.lastPathComponent
                    let subagentsDir = url.appendingPathComponent("subagents")
                    for sub in (try? fm.contentsOfDirectory(at: subagentsDir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
                    where sub.pathExtension == "jsonl" {
                        addCandidate(sub, subagent: true, sessionID: sessionID)
                    }
                }
            }
        }
        candidates.sort { $0.mtime > $1.mtime }

        // Bytes still owed across every dirty file, before this call spends any budget.
        var bytesTotal = 0
        for c in candidates {
            let cached = cache.files[c.url.path]
            if cached == nil || cached!.size != c.size {
                bytesTotal += owed(size: c.size, offset: cached?.offset ?? 0)
            }
        }

        var live: [String: FileEntry] = [:]
        var result = Result()
        result.bytesTotal = bytesTotal
        var budgetLeft = byteBudget
        var budgetSpent = false
        var filesTouched = 0

        for (i, c) in candidates.enumerated() {
            let cached = cache.files[c.url.path]
            let dirty = cached == nil || cached!.size != c.size

            if budgetSpent {
                // The pass is over — carry the cached state forward
                // untouched (a brand-new never-cached file is simply left
                // out; it's picked up fresh next call) and count every
                // still-dirty one toward what's owed.
                if let cached { live[c.url.path] = cached }
                result.files += 1
                if let cwd = cached?.cwd { result.cwds.insert(cwd) }
                for (key, day) in cached?.days ?? [:] { result.days[key] = (result.days[key] ?? Stats.Day()) + day }
                if dirty {
                    result.remaining += 1
                    result.bytesRemaining += owed(size: c.size, offset: cached?.offset ?? 0)
                }
                continue
            }

            var entry = cached ?? FileEntry()
            entry.subagent = c.subagent
            if dirty {
                if c.size < entry.offset { entry = FileEntry(); entry.subagent = c.subagent }   // shrink: start over
                while entry.offset < c.size {
                    if let left = budgetLeft, left <= 0 { budgetSpent = true; break }
                    let consumed = parse(url: c.url, sessionID: c.sessionID,
                                        into: &entry, calendar: calendar, windowBytes: windowBytes)
                    if consumed <= 0 {
                        // Nothing more to read right now: an unreadable
                        // file, or a trailing line that hasn't been
                        // newline-terminated yet. Retrying this call
                        // can't help either way, so latch `size` now —
                        // leaving it dirty forever would spin the caller
                        // (StatsModel's chunk loop) with no way out. The
                        // file becomes dirty again on its own once it
                        // actually grows (e.g. that last line finally
                        // gets its newline), picking up right where
                        // `offset` was left.
                        entry.size = c.size
                        break
                    }
                    if budgetLeft != nil { budgetLeft! -= consumed }
                }
                if entry.offset >= c.size { entry.size = c.size }   // caught up — only now does size==entry.size latch
                filesTouched += 1
                if let cacheURL, filesTouched % 200 == 0 {
                    var checkpoint = live
                    checkpoint[c.url.path] = entry
                    for other in candidates[(i + 1)...] where cache.files[other.url.path] != nil {
                        checkpoint[other.url.path] = cache.files[other.url.path]
                    }
                    var cp = cache
                    cp.files = checkpoint
                    writeCache(cp, to: cacheURL, fm: fm)
                }
            }
            live[c.url.path] = entry
            result.files += 1
            if let cwd = entry.cwd { result.cwds.insert(cwd) }
            for (key, day) in entry.days { result.days[key] = (result.days[key] ?? Stats.Day()) + day }
            if entry.size != c.size {
                result.remaining += 1
                result.bytesRemaining += owed(size: c.size, offset: entry.offset)
            }
        }
        cache.files = live
        if let cacheURL { writeCache(cache, to: cacheURL, fm: fm) }
        return result
    }

    private static let userMarker = Data("\"type\":\"user\"".utf8)
    private static let assistantMarker = Data("\"type\":\"assistant\"".utf8)
    private static let toolResultMarker = Data("\"tool_result\"".utf8)
    private static let timestampRegex = try! NSRegularExpression(pattern: "\"timestamp\":\"([^\"]+)\"")
    private static let isErrorTrueMarker = "\"is_error\":true"
    private static let toolDenialKindMarker = "\"toolDenialKind\""

    /// Avoids `JSONSerialization` on a big tool_result line (a giant
    /// command output can run hundreds of KB): a `"timestamp"` regex plus
    /// substring counts of `"is_error":true`/`"toolDenialKind"` feed a
    /// small synthesized object into the same `ingest`, so counting stays
    /// in one place. Returns nil (fall back to the real parse) if the
    /// timestamp can't be found.
    static func fastParseToolResult(_ line: Data) -> [String: Any]? {
        let s = String(decoding: line, as: UTF8.self)
        // The LAST match, not the first: the entry's own timestamp field
        // follows `message` in the JSON, and a tool result's content can
        // itself contain an embedded `"timestamp":"…"` (e.g. echoed API
        // output) that would otherwise be picked up instead.
        guard let match = timestampRegex.matches(in: s, range: NSRange(s.startIndex..., in: s)).last,
              let range = Range(match.range(at: 1), in: s) else { return nil }
        let errorCount = s.components(separatedBy: isErrorTrueMarker).count - 1
        var obj: [String: Any] = ["type": "user", "timestamp": String(s[range])]
        if s.contains(toolDenialKindMarker) { obj["toolDenialKind"] = true }
        let blocks = (0..<errorCount).map { _ in ["type": "tool_result", "is_error": true] as [String: Any] }
        obj["message"] = ["content": blocks]
        return obj
    }

    /// One read window's worth of bytes: 8 MB. `parse` never holds more
    /// than this (doubled only when a single line exceeds it) in memory
    /// at once, however large the file is.
    public static let windowBytes = 8 * 1024 * 1024

    /// Reads at most one bounded window starting at `entry.offset`,
    /// ingests every complete line in it, advances `entry.offset` past
    /// what it consumed, and returns the number of bytes consumed (0 if
    /// nothing could be — an unreadable file, or a trailing line that
    /// isn't newline-terminated yet).
    ///
    /// A window that comes back with no newline at all is ambiguous: it
    /// might be a single line bigger than the window (more data follows
    /// — double the window and re-read from the same offset; a line can
    /// never wedge the scan this way), or it might be the genuine end of
    /// the file with an in-progress last line (a short read: fewer bytes
    /// came back than asked for). Only the second case waits — same as
    /// the old unbounded `parse`, which held any line without a trailing
    /// newline for the next call.
    static func parse(url: URL, sessionID: String, into entry: inout FileEntry, calendar: Calendar,
                      windowBytes: Int = StatsScanner.windowBytes) -> Int {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }
        let newline = UInt8(ascii: "\n")
        var windowSize = windowBytes
        var data = Data()
        while true {
            guard (try? handle.seek(toOffset: UInt64(entry.offset))) != nil,
                  let chunk = try? handle.read(upToCount: windowSize), !chunk.isEmpty else { return 0 }
            data = chunk
            if data.lastIndex(of: newline) != nil { break }
            if chunk.count < windowSize { return 0 }   // real EOF, partial trailing line — wait
            windowSize *= 2
        }
        guard let lastNewline = data.lastIndex(of: newline) else { return 0 }
        let complete = data[data.startIndex...lastNewline]
        var lineStart = complete.startIndex
        while lineStart < complete.endIndex {
            let lineEnd = complete[lineStart...].firstIndex(of: newline) ?? complete.endIndex
            let line = complete[lineStart..<lineEnd]
            lineStart = lineEnd + 1
            // Cheap pre-filter: only user/assistant entries matter.
            let isUser = line.range(of: userMarker) != nil
            guard isUser || line.range(of: assistantMarker) != nil else { continue }
            var obj: [String: Any]?
            if isUser, line.range(of: toolResultMarker) != nil {
                obj = fastParseToolResult(line)
            }
            if obj == nil {
                obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            }
            guard let obj else { continue }
            ingest(obj, sessionID: sessionID, into: &entry, calendar: calendar)
        }
        entry.offset += complete.count
        return complete.count
    }
}
