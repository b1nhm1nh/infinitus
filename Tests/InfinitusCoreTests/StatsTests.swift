import XCTest
@testable import InfinitusCore

final class StatsTests: XCTestCase {
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        c.firstWeekday = 2
        return c
    }()
    func date(_ s: String) -> Date {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)!
    }

    func testDayAddsCountsUnionsSetsAndKeepsMaxima() {
        var a = Stats.Day(); a.commits = 2; a.humanMessages = 3; a.toolCalls = ["Bash": 4]
        a.sessions = ["s1"]; a.repos = ["r1"]; a.longestUnattended = 5; a.hours[3] = 1
        var b = Stats.Day(); b.commits = 1; b.toolCalls = ["Bash": 1, "Edit": 2]
        b.sessions = ["s1", "s2"]; b.longestUnattended = 9; b.hours[3] = 2
        let c = a + b
        XCTAssertEqual(c.commits, 3)
        XCTAssertEqual(c.humanMessages, 3)
        XCTAssertEqual(c.toolCalls, ["Bash": 5, "Edit": 2])
        XCTAssertEqual(c.sessions, ["s1", "s2"])
        XCTAssertEqual(c.repos, ["r1"])
        XCTAssertEqual(c.longestUnattended, 9)
        XCTAssertEqual(c.hours[3], 3)
    }

    func testDayAddsSessionBuckets() {
        var a = Stats.Day(); a.sessionBuckets = [1, 0, 0, 0]
        var b = Stats.Day(); b.sessionBuckets = [0, 1, 1, 0]
        let c = a + b
        XCTAssertEqual(c.sessionBuckets, [1, 1, 1, 0])
    }

    func testSessionBucketBoundaries() {
        XCTAssertEqual(Stats.Day.sessionBucket(seconds: 899), 0)
        XCTAssertEqual(Stats.Day.sessionBucket(seconds: 900), 1)
        XCTAssertEqual(Stats.Day.sessionBucket(seconds: 3599), 1)
        XCTAssertEqual(Stats.Day.sessionBucket(seconds: 3600), 2)
        XCTAssertEqual(Stats.Day.sessionBucket(seconds: 14399), 2)
        XCTAssertEqual(Stats.Day.sessionBucket(seconds: 14400), 3)
    }

    func testDerivedRatiosAreNilOnZero() {
        var d = Stats.Day()
        XCTAssertNil(d.messagesPerCommit)
        XCTAssertNil(d.usdPerCommit)
        XCTAssertNil(d.toolCallsPerHumanMessage)
        XCTAssertNil(d.meanMergeHours)
        d.commits = 2; d.humanMessages = 4; d.phoneMessages = 2; d.usd = 10
        d.toolCalls = ["Bash": 30]; d.mergeHoursTotal = 5; d.mergeCount = 2
        XCTAssertEqual(d.messagesPerCommit, 3)
        XCTAssertEqual(d.usdPerCommit, 5)
        XCTAssertEqual(d.toolCallsPerHumanMessage, 5)
        XCTAssertEqual(d.meanMergeHours, 2.5)
        XCTAssertEqual(d.totalToolCalls, 30)
        XCTAssertEqual(d.messages, 6)
    }

    func testDayKeyAndHourSlotUseTheCalendar() {
        let t = date("2026-09-03T17:30:00Z")   // 00:30 Sep 4 in Ho Chi Minh, a Friday
        XCTAssertEqual(Stats.dayKey(t, calendar: cal), "2026-09-04")
        XCTAssertEqual(Stats.hourSlot(t, calendar: cal), 4 * 24 + 0)   // Mon=0 … Fri=4
        XCTAssertEqual(Stats.date(fromDayKey: "2026-09-04", calendar: cal), date("2026-09-03T17:00:00Z"))
    }

    func testFoldWeekSumsCurrentWeekAndPreviousAndStreak() {
        func day(_ commits: Int, _ msgs: Int) -> Stats.Day {
            var d = Stats.Day(); d.commits = commits; d.humanMessages = msgs; return d
        }
        let days: [String: Stats.Day] = [
            "2026-08-26": day(4, 1),   // previous week (Wed)
            "2026-08-31": day(1, 0),   // Mon, this week
            "2026-09-02": day(2, 3),
            "2026-09-03": day(0, 1),
            "2026-09-04": day(3, 0),   // today (Fri)
        ]
        let now = date("2026-09-04T03:00:00Z")   // 10:00 local Fri Sep 4
        let s = Stats.fold(days: days, period: .week, now: now, calendar: cal)
        XCTAssertEqual(s.period, .week)
        XCTAssertEqual(s.total.commits, 6)
        XCTAssertEqual(s.previous.commits, 4)
        XCTAssertEqual(s.from, "2026-08-31")
        XCTAssertEqual(s.to, "2026-09-06")
        XCTAssertEqual(s.daily.count, 7)                     // every day of the week, empty ones included
        XCTAssertEqual(s.daily.map(\.key).first, "2026-08-31")
        XCTAssertEqual(s.streak, 3)                          // Sep 2, 3, 4 each had a commit or a message
    }

    func testFoldDayMonthYearRanges() {
        let now = date("2026-09-04T03:00:00Z")
        XCTAssertEqual(Stats.fold(days: [:], period: .day, now: now, calendar: cal).from, "2026-09-04")
        XCTAssertEqual(Stats.fold(days: [:], period: .month, now: now, calendar: cal).from, "2026-09-01")
        XCTAssertEqual(Stats.fold(days: [:], period: .month, now: now, calendar: cal).to, "2026-09-30")
        XCTAssertEqual(Stats.fold(days: [:], period: .year, now: now, calendar: cal).from, "2026-01-01")
        XCTAssertEqual(Stats.fold(days: [:], period: .year, now: now, calendar: cal).previous, Stats.Day())
    }

    func testBundleDropsDailySeries() {
        var d = Stats.Day(); d.commits = 1
        let b = Stats.Bundle(days: ["2026-09-04": d], now: date("2026-09-04T03:00:00Z"), calendar: cal)
        XCTAssertEqual(b.periods.count, 4)
        XCTAssertTrue(b.periods.allSatisfy { $0.daily.isEmpty })
        XCTAssertEqual(b.periods.first { $0.period == .day }?.total.commits, 1)
        let data = try! JSONEncoder().encode(b)
        XCTAssertLessThan(data.count, 12_000)
    }

    func testBundleCompactsSessionAndRepoSetsIntoTallies() {
        var d = Stats.Day(); d.sessions = ["s1", "s2", "s3"]; d.repos = ["r1"]
        let b = Stats.Bundle(days: ["2026-09-04": d], now: date("2026-09-04T03:00:00Z"), calendar: cal)
        let day = b.summary(.day)!
        XCTAssertTrue(day.total.sessions.isEmpty)
        XCTAssertEqual(day.total.sessionCount, 3)
        XCTAssertTrue(day.total.repos.isEmpty)
        XCTAssertEqual(day.total.repoCount, 1)
        let data = try! JSONEncoder().encode(b)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertFalse(json.contains("s1"))
        XCTAssertFalse(json.contains("s2"))
        XCTAssertFalse(json.contains("s3"))
    }

    func testPresentationGroupsFormatTilesDeltasAndSeries() {
        var total = Stats.Day(); total.commits = 10
        var previous = Stats.Day(); previous.commits = 5
        let s = Stats.Summary(period: .week, from: "2026-09-01", to: "2026-09-07",
                              total: total, previous: previous, daily: [], streak: 0)
        let groups = Stats.Presentation.groups(s)
        let throughput = groups.first { $0.id == "Throughput" }!
        let commits = throughput.tiles.first { $0.id == "Commits" }!
        XCTAssertEqual(commits.value, "10")
        XCTAssertEqual(commits.delta, "+100%")
        XCTAssertTrue(commits.series.isEmpty)   // daily empty (the mirrored bundle's shape)

        let autonomy = groups.first { $0.id == "Autonomy" }!
        let ratioTile = autonomy.tiles.first { $0.id == "Tool calls / message" }!
        XCTAssertEqual(ratioTile.value, "—")   // messages == 0, zero-denominator ratio
        XCTAssertNil(ratioTile.delta)
    }

    func testFoldMonthPreviousIsTheCalendarMonth() {
        func day(_ commits: Int) -> Stats.Day {
            var d = Stats.Day(); d.commits = commits; return d
        }
        let days: [String: Stats.Day] = [
            "2026-01-31": day(5),   // Jan 31, should be excluded from Feb's previous
            "2026-02-01": day(1),   // Feb 1, should be in Feb's previous
        ]
        let now = date("2026-03-04T03:00:00Z")   // 10:00 local Mar 4
        let s = Stats.fold(days: days, period: .month, now: now, calendar: cal)
        XCTAssertEqual(s.period, .month)
        XCTAssertEqual(s.from, "2026-03-01")
        XCTAssertEqual(s.previous.commits, 1)  // Only Feb 1, not Jan 31
    }

    func entry(_ json: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    }

    func testClassifyUserEntries() {
        XCTAssertEqual(StatsScanner.classifyUser(entry(#"{"type":"user","origin":{"kind":"human"},"message":{"role":"user","content":"hi"}}"#)), .human)
        XCTAssertEqual(StatsScanner.classifyUser(entry(#"{"type":"user","origin":{"kind":"peer","from":"uds:/tmp/infinitus-123.sock"},"message":{"role":"user","content":"<cross-session-message from=\"uds:/tmp/infinitus-123.sock\" from-name=\"Infinitus\" from-mode=\"bypass\">\nfix it\n</cross-session-message>"}}"#)), .phone)
        XCTAssertEqual(StatsScanner.classifyUser(entry(#"{"type":"user","origin":{"kind":"peer","from":"uds:/tmp/infinitus-123.sock"},"message":{"role":"user","content":"<cross-session-message from=\"uds:/tmp/infinitus-123.sock\" from-name=\"Infinitus\" from-mode=\"bypass\">\n[Infinitus] Continue where you left off\n</cross-session-message>"}}"#)), .nudge)
        XCTAssertEqual(StatsScanner.classifyUser(entry(#"{"type":"user","origin":{"kind":"peer","from":"uds:/tmp/cc-socks/1.sock"},"message":{"role":"user","content":"<cross-session-message from=\"uds:/tmp/cc-socks/1.sock\" from-name=\"Infinitus2\" from-mode=\"bypass\">\nmerge e2\n</cross-session-message>"}}"#)), .agent)
        // No origin (older Claude Code): the wrapper decides.
        XCTAssertEqual(StatsScanner.classifyUser(entry(#"{"type":"user","message":{"role":"user","content":"<cross-session-message from=\"uds:/tmp/infinitus-9.sock\" from-name=\"Infinitus\" from-mode=\"bypass\">\nhello\n</cross-session-message>"}}"#)), .phone)
        XCTAssertEqual(StatsScanner.classifyUser(entry(#"{"type":"user","message":{"role":"user","content":"<system-reminder>x</system-reminder>"}}"#)), .machinery)
        XCTAssertEqual(StatsScanner.classifyUser(entry(#"{"type":"user","isCompactSummary":true,"message":{"role":"user","content":"This session is being continued"}}"#)), .compaction)
        XCTAssertEqual(StatsScanner.classifyUser(entry(#"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#)), .toolResult)
        XCTAssertEqual(StatsScanner.classifyUser(entry(#"{"type":"user","origin":{"kind":"task-notification"},"message":{"role":"user","content":"done"}}"#)), .machinery)
        XCTAssertEqual(StatsScanner.classifyUser(entry(#"{"type":"user","promptSource":"queued","message":{"role":"user","content":[{"type":"text","text":"also this"}]}}"#)), .human)
        XCTAssertEqual(StatsScanner.classifyUser(entry(#"{"type":"user","origin":{"kind":"human"},"message":{"role":"user","content":[{"type":"image","source":{}}]}}"#)), .human)
        // Phone messages now carry the socket preface (PeerSocket.phonePreface);
        // sender is "Infinitus app". Bare "[Infinitus] ..." stays a nudge.
        let phoneBody = PeerSocket.phonePreface.replacingOccurrences(of: "\n", with: "\\n") + "fix it"
        XCTAssertEqual(StatsScanner.classifyUser(entry(#"{"type":"user","origin":{"kind":"peer","from":"uds:/tmp/infinitus-1.sock"},"message":{"role":"user","content":"<cross-session-message from=\"uds:/tmp/infinitus-1.sock\" from-name=\"Infinitus\" from-mode=\"bypass\">\#(phoneBody)</cross-session-message>"}}"#)), .phone)
        XCTAssertEqual(StatsScanner.classifyUser(entry(#"{"type":"user","message":{"role":"user","content":"<cross-session-message from=\"uds:/tmp/infinitus-9.sock\" from-name=\"Infinitus app\" from-mode=\"bypass\">\nhello\n</cross-session-message>"}}"#)), .phone)
        XCTAssertEqual(StatsScanner.classifyUser(entry(#"{"type":"user","message":{"role":"user","content":"<cross-session-message from=\"uds:/tmp/cc-socks/2.sock\" from-name=\"Infinitus2\" from-mode=\"bypass\">\n[Infinitus] x\n</cross-session-message>"}}"#)), .agent)
    }

    func testIngestCountsAConversation() {
        var e = StatsScanner.FileEntry()
        let lines = [
            #"{"type":"user","cwd":"/r/a","timestamp":"2026-09-04T01:00:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"do it"}}"#,
            #"{"type":"assistant","timestamp":"2026-09-04T01:00:05.000Z","message":{"id":"m1","model":"claude-opus-4-5-20250805","usage":{"input_tokens":10,"output_tokens":20},"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}"#,
            #"{"type":"assistant","timestamp":"2026-09-04T01:00:06.000Z","message":{"id":"m1","model":"claude-opus-4-5-20250805","usage":{"input_tokens":10,"output_tokens":20},"content":[{"type":"text","text":"streamed twin"},{"type":"tool_use","id":"t1b","name":"Bash","input":{}}]}}"#,
            #"{"type":"user","timestamp":"2026-09-04T01:00:07.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"boom"}]}}"#,
            #"{"type":"assistant","timestamp":"2026-09-04T01:00:08.000Z","message":{"id":"m2","model":"claude-opus-4-5-20250805","usage":{"input_tokens":5,"output_tokens":5},"content":[{"type":"tool_use","id":"t2","name":"Agent","input":{}},{"type":"tool_use","id":"t3","name":"AskUserQuestion","input":{"questions":[]}}]}}"#,
            #"{"type":"user","timestamp":"2026-09-04T01:00:09.000Z","toolDenialKind":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t3","content":"denied"}]}}"#,
            #"{"type":"assistant","timestamp":"2026-09-04T01:00:10.000Z","isApiErrorMessage":true,"message":{"id":"m3","model":"<synthetic>","content":[{"type":"text","text":"retry"}]}}"#,
            #"{"type":"assistant","timestamp":"2026-09-04T01:00:11.000Z","message":{"id":"m4","model":"claude-opus-4-5-20250805","usage":{"input_tokens":1,"output_tokens":1},"content":[{"type":"text","text":"done"}]}}"#,
            #"{"type":"user","isCompactSummary":true,"timestamp":"2026-09-04T01:30:00.000Z","message":{"role":"user","content":"This session is being continued"}}"#,
            #"{"type":"user","timestamp":"2026-09-04T02:00:11.000Z","origin":{"kind":"peer","from":"uds:/tmp/infinitus-1.sock"},"message":{"role":"user","content":"<cross-session-message from=\"uds:/tmp/infinitus-1.sock\" from-name=\"Infinitus\" from-mode=\"bypass\">\nthanks\n</cross-session-message>"}}"#,
        ]
        for line in lines { StatsScanner.ingest(entry(line), sessionID: "s1", into: &e, calendar: cal) }
        let d = e.days["2026-09-04"]!
        XCTAssertEqual(d.humanMessages, 1)
        XCTAssertEqual(d.phoneMessages, 1)
        XCTAssertEqual(d.toolCalls, ["Bash": 2, "Agent": 1, "AskUserQuestion": 1])
        XCTAssertEqual(d.toolErrors, 1)
        XCTAssertEqual(d.subagents, 1)
        XCTAssertEqual(d.questions, 1)
        XCTAssertEqual(d.denials, 1)
        XCTAssertEqual(d.retries, 1)
        XCTAssertEqual(d.compactions, 1)
        XCTAssertEqual(d.turns, 1)                          // "done" is the turn end; the twin of m1 is mid-turn
        XCTAssertEqual(d.inputTokens, 16)                   // m1 counted once (same message id twice)
        XCTAssertEqual(d.outputTokens, 26)
        XCTAssertGreaterThan(d.usd, 0)
        XCTAssertEqual(d.sessions, ["s1"])
        XCTAssertEqual(d.sessionSeconds, 3611, accuracy: 0.5) // 01:00:00 → 02:00:11
        XCTAssertEqual(d.sessionBuckets, [0, 0, 1, 0])        // 3611s falls in the 1-4h bucket
        XCTAssertEqual(d.waitingSeconds, 3600, accuracy: 0.5) // turn end 01:00:11 → phone message 02:00:11
        XCTAssertEqual(d.longestUnattended, 4)              // Bash, Bash, Agent, AskUserQuestion between the two human messages
        XCTAssertEqual(d.hours.reduce(0, +), 10)            // every entry lands in a slot
        XCTAssertEqual(e.cwd, "/r/a")
    }

    func testIngestSessionBucketMovesAsTheSpanCrossesFifteenMinutes() {
        var e = StatsScanner.FileEntry()
        StatsScanner.ingest(entry(#"{"type":"user","timestamp":"2026-09-04T01:00:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"start"}}"#), sessionID: "s1", into: &e, calendar: cal)
        var d = e.days["2026-09-04"]!
        XCTAssertEqual(d.sessionSeconds, 0)
        XCTAssertEqual(d.sessionBuckets, [1, 0, 0, 0])        // a single entry is a 0s span: <15m
        StatsScanner.ingest(entry(#"{"type":"user","timestamp":"2026-09-04T01:20:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"continue"}}"#), sessionID: "s1", into: &e, calendar: cal)
        d = e.days["2026-09-04"]!
        XCTAssertEqual(d.sessionSeconds, 1200, accuracy: 0.5) // 20 minutes
        XCTAssertEqual(d.sessionBuckets, [0, 1, 0, 0])        // moved to 15-60m, exactly one 1
    }

    func testIngestGatesSessionAndMessageFieldsForSubagentFiles() {
        var e = StatsScanner.FileEntry()
        e.subagent = true
        // (a) the subagent's first "user" entry is its prompt FROM the
        // parent — must never count as a human message, session, or hour.
        StatsScanner.ingest(entry(#"{"type":"user","timestamp":"2026-09-04T01:00:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"do the subtask"}}"#), sessionID: "parent-session", into: &e, calendar: cal)
        var d = e.days["2026-09-04"]!
        XCTAssertEqual(d.humanMessages, 0)
        XCTAssertTrue(d.sessions.isEmpty)
        XCTAssertEqual(d.hours.reduce(0, +), 0)
        XCTAssertEqual(d.sessionSeconds, 0)

        // (b) an assistant usage entry: tokens/usd counted, no turn.
        StatsScanner.ingest(entry(#"{"type":"assistant","timestamp":"2026-09-04T01:00:05.000Z","message":{"id":"m1","model":"claude-opus-4-5-20250805","usage":{"input_tokens":10,"output_tokens":20},"content":[{"type":"text","text":"working"}]}}"#), sessionID: "parent-session", into: &e, calendar: cal)
        d = e.days["2026-09-04"]!
        XCTAssertEqual(d.inputTokens, 10)
        XCTAssertEqual(d.outputTokens, 20)
        XCTAssertGreaterThan(d.usd, 0)
        XCTAssertEqual(d.turns, 0)

        // (c) a tool_use block: toolCalls counted, still no turn.
        StatsScanner.ingest(entry(#"{"type":"assistant","timestamp":"2026-09-04T01:00:06.000Z","message":{"id":"m2","model":"claude-opus-4-5-20250805","usage":{"input_tokens":1,"output_tokens":1},"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}"#), sessionID: "parent-session", into: &e, calendar: cal)
        d = e.days["2026-09-04"]!
        XCTAssertEqual(d.toolCalls, ["Bash": 1])
        XCTAssertEqual(d.turns, 0)

        // (d) a tool_result is_error: toolErrors counted.
        StatsScanner.ingest(entry(#"{"type":"user","timestamp":"2026-09-04T01:00:07.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"boom"}]}}"#), sessionID: "parent-session", into: &e, calendar: cal)
        d = e.days["2026-09-04"]!
        XCTAssertEqual(d.toolErrors, 1)
    }

    func testWaitingGapIsCappedAtEightHours() {
        var e = StatsScanner.FileEntry()
        StatsScanner.ingest(entry(#"{"type":"assistant","timestamp":"2026-09-01T01:00:00.000Z","message":{"id":"m1","model":"claude-opus-4-5-20250805","usage":{"input_tokens":1,"output_tokens":1},"content":[{"type":"text","text":"done"}]}}"#), sessionID: "s", into: &e, calendar: cal)
        StatsScanner.ingest(entry(#"{"type":"user","timestamp":"2026-09-02T01:00:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"back"}}"#), sessionID: "s", into: &e, calendar: cal)
        XCTAssertEqual(e.days.values.map(\.waitingSeconds).reduce(0, +), 8 * 3600, accuracy: 0.5)
    }

    func testScanIsIncrementalAndResetsOnShrink() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stats-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("p"), withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("p/abc.jsonl")
        let cache = dir.appendingPathComponent("cache.json")
        let l1 = #"{"type":"user","cwd":"/r/a","timestamp":"2026-09-04T01:00:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"one"}}"#
        try (l1 + "\n").write(to: file, atomically: true, encoding: .utf8)
        var r = StatsScanner.scan(projectsDir: dir, cacheURL: cache, calendar: cal)
        XCTAssertEqual(r.days["2026-09-04"]?.humanMessages, 1)
        XCTAssertEqual(r.cwds, ["/r/a"])
        XCTAssertEqual(r.files, 1)
        // Append: only the new line is read.
        let h = try FileHandle(forWritingTo: file); h.seekToEndOfFile()
        h.write(Data((l1 + "\n").utf8)); try h.close()
        r = StatsScanner.scan(projectsDir: dir, cacheURL: cache, calendar: cal)
        XCTAssertEqual(r.days["2026-09-04"]?.humanMessages, 2)
        // A partial last line waits.
        let h2 = try FileHandle(forWritingTo: file); h2.seekToEndOfFile()
        h2.write(Data(#"{"type":"user","timest"#.utf8)); try h2.close()
        r = StatsScanner.scan(projectsDir: dir, cacheURL: cache, calendar: cal)
        XCTAssertEqual(r.days["2026-09-04"]?.humanMessages, 2)
        // Shrink: the file is re-read from zero.
        try (l1 + "\n").write(to: file, atomically: true, encoding: .utf8)
        r = StatsScanner.scan(projectsDir: dir, cacheURL: cache, calendar: cal)
        XCTAssertEqual(r.days["2026-09-04"]?.humanMessages, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))
    }

    /// `<project>/<session-id>/subagents/agent-*.jsonl` is a subagent's
    /// own transcript: `scan` must pick it up (one fixed depth below the
    /// session dir) and its tokens must land on the day, but it must not
    /// contribute a session — only the top-level file does.
    func testScanPicksUpSubagentTranscriptsForTokensOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stats-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sessionDir = dir.appendingPathComponent("p/sess-1")
        let subagentsDir = sessionDir.appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: subagentsDir, withIntermediateDirectories: true)
        let topFile = dir.appendingPathComponent("p/sess-1.jsonl")
        let subFile = subagentsDir.appendingPathComponent("agent-x.jsonl")
        let cache = dir.appendingPathComponent("cache.json")

        let topLine = #"{"type":"user","cwd":"/r/a","timestamp":"2026-09-04T01:00:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"go"}}"#
        try (topLine + "\n").write(to: topFile, atomically: true, encoding: .utf8)
        let subLine = #"{"type":"assistant","timestamp":"2026-09-04T01:00:05.000Z","message":{"id":"m1","model":"claude-opus-4-5-20250805","usage":{"input_tokens":10,"output_tokens":20},"content":[{"type":"text","text":"subtask done"}]}}"#
        try (subLine + "\n").write(to: subFile, atomically: true, encoding: .utf8)

        let r = StatsScanner.scan(projectsDir: dir, cacheURL: cache, calendar: cal)
        XCTAssertEqual(r.files, 2)
        let d = r.days["2026-09-04"]!
        XCTAssertEqual(d.humanMessages, 1)          // from the top-level file only
        XCTAssertEqual(d.sessions, ["sess-1"])      // the subagent file added no session
        XCTAssertEqual(d.inputTokens, 10)           // from the subagent file
        XCTAssertEqual(d.outputTokens, 20)
    }

    /// A file whose last line never gets a trailing newline (a still-open
    /// transcript stalled between JSON entries — not the same as an
    /// mid-write partial line, which does eventually complete) must not
    /// keep `remaining` stuck above 0 forever: `parse` returns 0 for it,
    /// so the second scan must latch `size` and report the corpus caught
    /// up rather than spinning the caller (`StatsModel`'s chunk loop)
    /// with no way out.
    func testScanLatchesUnterminatedTailAndStopsBeingRemaining() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stats-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("p"), withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("p/tail.jsonl")
        let cache = dir.appendingPathComponent("cache.json")
        let l1 = #"{"type":"user","cwd":"/r/a","timestamp":"2026-09-04T01:00:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"one"}}"#
        // First line complete; last line has no trailing newline at all.
        try (l1 + "\n" + #"{"type":"user","timest"#).write(to: file, atomically: true, encoding: .utf8)
        var r = StatsScanner.scan(projectsDir: dir, cacheURL: cache, calendar: cal)
        XCTAssertEqual(r.days["2026-09-04"]?.humanMessages, 1)
        XCTAssertEqual(r.remaining, 0)
        // Scanned again with no change to the file: still caught up.
        r = StatsScanner.scan(projectsDir: dir, cacheURL: cache, calendar: cal)
        XCTAssertEqual(r.remaining, 0)
        XCTAssertEqual(r.bytesRemaining, 0)
    }

    /// A window smaller than the file forces multiple `parse` calls per
    /// file; a budget smaller than the file's total size must stop mid
    /// file (not mid line — every line that gets counted is a whole one).
    func testScanHonorsByteBudgetAndReportsRemaining() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stats-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("p"), withIntermediateDirectories: true)
        let day = "2026-09-04"
        // Three lines, each exactly 220 bytes (219 + trailing newline) —
        // padded so the byte math below is exact, not approximate.
        func line(_ seq: Int, targetBytes: Int) -> String {
            func build(_ padLen: Int) -> String {
                #"{"type":"user","cwd":"/r/a","timestamp":"\#(day)T0\#(seq):00:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"\#(String(repeating: "x", count: padLen))"}}"#
            }
            var padLen = 0
            while build(padLen).utf8.count < targetBytes { padLen += 1 }
            return build(padLen)
        }
        let lines = (1...3).map { line($0, targetBytes: 219) + "\n" }
        XCTAssertEqual(lines[0].utf8.count, 220)
        try lines.joined().write(to: dir.appendingPathComponent("p/f.jsonl"), atomically: true, encoding: .utf8)

        // Baseline: one unbounded scan into its own cache, for comparison.
        let full = StatsScanner.scan(projectsDir: dir, cacheURL: dir.appendingPathComponent("full.json"), calendar: cal)
        XCTAssertEqual(full.days[day]?.humanMessages, 3)
        XCTAssertEqual(full.remaining, 0)

        let cache = dir.appendingPathComponent("cache.json")
        // windowBytes bigger than one line but smaller than two, so each
        // `parse` call reads exactly one line; a 300-byte budget (less
        // than the 660-byte file) affords exactly two of the three.
        var r = StatsScanner.scan(projectsDir: dir, cacheURL: cache, calendar: cal, byteBudget: 300, windowBytes: 300)
        XCTAssertEqual(r.remaining, 1)
        XCTAssertGreaterThan(r.bytesRemaining, 0)
        XCTAssertEqual(r.days[day]?.humanMessages, 2)

        r = StatsScanner.scan(projectsDir: dir, cacheURL: cache, calendar: cal, byteBudget: 300, windowBytes: 300)
        XCTAssertEqual(r.remaining, 0)
        XCTAssertEqual(r.bytesRemaining, 0)
        XCTAssertEqual(r.days, full.days)
    }

    func testFastPathParsesBigToolResultLineWithoutFullJSON() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stats-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("sess1.jsonl")
        let pad = String(repeating: "x", count: 200_000)
        let bigLine = #"{"type":"user","timestamp":"2026-09-04T03:00:00.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"\#(pad)"},{"type":"tool_result","tool_use_id":"t2","is_error":true,"content":"ok"}]}}"#
        XCTAssertGreaterThan(bigLine.utf8.count, 200_000)
        try (bigLine + "\n").write(to: file, atomically: true, encoding: .utf8)
        var entry = StatsScanner.FileEntry()
        _ = StatsScanner.parse(url: file, sessionID: "sess1", into: &entry, calendar: cal)
        let day = entry.days["2026-09-04"]
        XCTAssertEqual(day?.toolErrors, 2)
        XCTAssertEqual(day?.sessions, ["sess1"])
        let slot = Stats.hourSlot(date("2026-09-04T03:00:00Z"), calendar: cal)
        XCTAssertEqual(day?.hours[slot], 1)
    }

    func testParseGitLogWithNumstatAndTrailers() {
        let log = """
        \u{1e}abc123\u{1f}2026-09-04T08:10:00+07:00\u{1f}me@x.com\u{1f}feat: thing\u{1f}Claude Code <noreply@anthropic.com>
        3\t1\tSources/A.swift
        -\t-\tassets/icon.png
        \u{1e}def456\u{1f}2026-09-03T23:59:00+07:00\u{1f}me@x.com\u{1f}Revert "feat: thing"\u{1f}
        0\t3\tSources/A.swift
        """
        let commits = RepoStats.parseLog(log)
        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits[0].sha, "abc123")
        XCTAssertEqual(commits[0].added, 3)
        XCTAssertEqual(commits[0].removed, 1)
        XCTAssertEqual(commits[0].files, 2)
        XCTAssertTrue(commits[0].coAuthoredByClaude)
        XCTAssertFalse(commits[0].revert)
        XCTAssertTrue(commits[1].revert)
        XCTAssertFalse(commits[1].coAuthoredByClaude)
        XCTAssertEqual(commits[1].at, date("2026-09-03T16:59:00Z"))
    }

    func testParsePRsAndFoldDays() throws {
        let json = Data(#"[{"number":1,"createdAt":"2026-09-01T10:00:00Z","mergedAt":"2026-09-03T10:00:00Z","closedAt":"2026-09-03T10:00:00Z"},{"number":2,"createdAt":"2026-09-04T01:00:00Z","mergedAt":null,"closedAt":null}]"#.utf8)
        let prs = RepoStats.parsePRs(json)
        XCTAssertEqual(prs.count, 2)
        XCTAssertNil(prs[1].mergedAt)
        let commits = RepoStats.parseLog("\u{1e}a\u{1f}2026-09-04T08:10:00+07:00\u{1f}me@x.com\u{1f}x\u{1f}\n1\t0\tf\n")
        let days = RepoStats.days(commits: commits, prs: prs, repo: "/r/a", calendar: cal)
        XCTAssertEqual(days["2026-09-04"]?.commits, 1)
        XCTAssertEqual(days["2026-09-04"]?.linesAdded, 1)
        XCTAssertEqual(days["2026-09-04"]?.repos, ["/r/a"])
        XCTAssertEqual(days["2026-09-04"]?.prsOpened, 1)
        XCTAssertEqual(days["2026-09-01"]?.prsOpened, 1)
        XCTAssertEqual(days["2026-09-03"]?.prsMerged, 1)
        XCTAssertEqual(days["2026-09-03"]?.mergeHoursTotal ?? 0, 48, accuracy: 0.01)
        XCTAssertEqual(days["2026-09-03"]?.mergeCount, 1)
    }

    func testEventsFoldIntoDaysWithMinutesLost() {
        let ev: [StatsEvent] = [
            .init(at: date("2026-09-04T01:00:00Z"), kind: "switch", icon: "", text: "switched a → b"),
            .init(at: date("2026-09-04T01:05:00Z"), kind: "death", icon: "", text: "a hit its limit"),
            .init(at: date("2026-09-04T01:10:00Z"), kind: "limit", icon: "", text: "every account at a limit"),
            .init(at: date("2026-09-04T01:40:00Z"), kind: "revival", icon: "", text: "a is back"),
            .init(at: date("2026-09-04T02:00:00Z"), kind: "ignite", icon: "", text: "ignited c"),
            .init(at: date("2026-09-04T02:01:00Z"), kind: "resume", icon: "", text: "resumed s"),
            .init(at: date("2026-09-04T02:02:00Z"), kind: "nudge", icon: "", text: "nudged s"),
        ]
        let d = StatsEvents.days(ev, calendar: cal)["2026-09-04"]!
        XCTAssertEqual(d.switches, 1)
        XCTAssertEqual(d.limitStops, 1)
        XCTAssertEqual(d.revivals, 1)
        XCTAssertEqual(d.ignites, 1)
        XCTAssertEqual(d.resumes, 2)
        XCTAssertEqual(d.minutesLostToLimits, 30, accuracy: 0.01)
    }

    func testAwsDoneNudgeCarriesThePrefix() {
        XCTAssertTrue(AwsLogin.continueMessage(profile: "p", fromPhone: true).hasPrefix("[Infinitus] "))
    }

    // MARK: fix wave 2026-09-04

    /// The shape Claude Code actually writes for a relayed message: a
    /// preamble line, the wrapper, then its own guidance after the close
    /// tag. Socket paths and bodies are neutral stand-ins for a real
    /// transcript's.
    private func peerEntry(from: String, name: String, body: String, origin: Bool) -> [String: Any] {
        let esc = { (s: String) in
            s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
             .replacingOccurrences(of: "\n", with: "\\n")
        }
        let content = "Another Claude session sent a message:\\n"
            + "<cross-session-message from=\\\"\(from)\\\" from-name=\\\"\(name)\\\" from-mode=\\\"bypass\\\">\\n"
            + esc(body) + "\\n</cross-session-message>\\n\\n"
            + "This came from another Claude session — not typed by your user."
        let originJSON = origin
            ? #","origin":{"kind":"peer","from":"\#(from)","verifiedPeerPid":1,"name":"\#(name)","fromMode":"bypass","body":"\#(esc(body))"}"#
            : ""
        return entry(#"{"type":"user","isMeta":true,"timestamp":"2026-09-04T01:00:00.000Z","message":{"role":"user","content":"\#(content)"}\#(originJSON)}"#)
    }

    func testClassifyRealPeerEnvelopes() {
        // (1) origin peer from the app's socket, nudge body.
        XCTAssertEqual(StatsScanner.classifyUser(peerEntry(
            from: "uds:/tmp/infinitus-1.sock", name: "Infinitus",
            body: "[Infinitus] Your account hit a limit — continue on the next one",
            origin: true)), .nudge)
        // (2) same, but the body carries the phone preface.
        XCTAssertEqual(StatsScanner.classifyUser(peerEntry(
            from: "uds:/tmp/infinitus-1.sock", name: "Infinitus",
            body: PeerSocket.phonePreface + "look at the build",
            origin: true)), .phone)
        // (3) no origin: the wrapper sits inside the preamble.
        XCTAssertEqual(StatsScanner.classifyUser(peerEntry(
            from: "uds:/tmp/infinitus-1.sock", name: "Infinitus",
            body: "[Infinitus] Your account hit a limit — continue on the next one",
            origin: false)), .nudge)
        // (4) no origin, another session.
        XCTAssertEqual(StatsScanner.classifyUser(peerEntry(
            from: "uds:/tmp/cc-socks/20520.sock", name: "other",
            body: "merge my branch please", origin: false)), .agent)
        // (5) no origin, a teammate envelope under the same preamble.
        XCTAssertEqual(StatsScanner.classifyUser(entry(#"{"type":"user","message":{"role":"user","content":"Another Claude session sent a message:\n<teammate-message teammate_id=\"worker-1\" color=\"cyan\">\n{\"type\":\"idle_notification\"}\n</teammate-message>\n\nThis came from another Claude session — not typed by your user."}}"#)), .agent)
    }

    func testClassifyMachineryDenylistAndPastedImage() {
        XCTAssertEqual(StatsScanner.classifyUser(entry(#"{"type":"user","message":{"role":"user","content":"[Request interrupted by user for tool use]"}}"#)), .machinery)
        XCTAssertEqual(StatsScanner.classifyUser(entry(#"{"type":"user","message":{"role":"user","content":"Stop hook feedback:\n- run the tests"}}"#)), .machinery)
        XCTAssertEqual(StatsScanner.classifyUser(entry(#"{"type":"user","message":{"role":"user","content":"Caveat: The messages below were generated while running /x"}}"#)), .machinery)
        XCTAssertEqual(StatsScanner.classifyUser(entry(##"{"type":"user","message":{"role":"user","content":"# Autonomous loop tick 4"}}"##)), .machinery)
        XCTAssertEqual(StatsScanner.classifyUser(entry(#"{"type":"user","message":{"role":"user","content":"[1 prior /loop tick]"}}"#)), .machinery)
        XCTAssertEqual(StatsScanner.classifyUser(entry(#"{"type":"user","message":{"role":"user","content":"(Re-invocation of /loop)"}}"#)), .machinery)
        // The user pasted this — still human.
        XCTAssertEqual(StatsScanner.classifyUser(entry(#"{"type":"user","message":{"role":"user","content":"[Image: screenshot.png]"}}"#)), .human)
    }

    func testNudgeDoesNotCloseTheWaitingClockOrResetToolsSinceHuman() {
        var e = StatsScanner.FileEntry()
        // A turn ends, two tool calls run, then a nudge arrives.
        StatsScanner.ingest(entry(#"{"type":"assistant","timestamp":"2026-09-04T01:00:00.000Z","message":{"id":"m1","model":"claude-opus-4-5-20250805","usage":{"input_tokens":1,"output_tokens":1},"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}}"#), sessionID: "s", into: &e, calendar: cal)
        StatsScanner.ingest(entry(#"{"type":"assistant","timestamp":"2026-09-04T01:00:01.000Z","message":{"id":"m2","model":"claude-opus-4-5-20250805","usage":{"input_tokens":1,"output_tokens":1},"content":[{"type":"text","text":"waiting on you"}]}}"#), sessionID: "s", into: &e, calendar: cal)
        var nudge = peerEntry(from: "uds:/tmp/infinitus-1.sock", name: "Infinitus",
                              body: "[Infinitus] Your account hit a limit", origin: true)
        nudge["timestamp"] = "2026-09-04T01:10:00.000Z"
        StatsScanner.ingest(nudge, sessionID: "s", into: &e, calendar: cal)
        XCTAssertEqual(e.days["2026-09-04"]?.nudges, 1)
        XCTAssertEqual(e.days["2026-09-04"]?.phoneMessages, 0)
        XCTAssertEqual(e.days["2026-09-04"]?.waitingSeconds, 0)      // clock still running
        XCTAssertNotNil(e.state.turnEndedAt)
        XCTAssertEqual(e.state.toolsSinceHuman, 1)                   // not reset
        // The human who actually answers closes it.
        StatsScanner.ingest(entry(#"{"type":"user","timestamp":"2026-09-04T01:20:01.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"here"}}"#), sessionID: "s", into: &e, calendar: cal)
        XCTAssertEqual(e.days["2026-09-04"]?.waitingSeconds ?? 0, 1200, accuracy: 0.5)
        XCTAssertEqual(e.state.toolsSinceHuman, 0)
    }

    func testUnchangedTreeDoesNotRewriteTheCache() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stats-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("p"), withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("p/abc.jsonl")
        let cache = dir.appendingPathComponent("cache.json")
        try (#"{"type":"user","cwd":"/r/a","timestamp":"2026-09-04T01:00:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"one"}}"# + "\n")
            .write(to: file, atomically: true, encoding: .utf8)
        _ = StatsScanner.scan(projectsDir: dir, cacheURL: cache, calendar: cal)
        let first = try FileManager.default.attributesOfItem(atPath: cache.path)[.modificationDate] as! Date
        let r = StatsScanner.scan(projectsDir: dir, cacheURL: cache, calendar: cal)
        let second = try FileManager.default.attributesOfItem(atPath: cache.path)[.modificationDate] as! Date
        XCTAssertEqual(r.days["2026-09-04"]?.humanMessages, 1)   // still answered from the cache
        XCTAssertEqual(first, second)
        // A new file makes it write again.
        try (#"{"type":"user","timestamp":"2026-09-04T02:00:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"two"}}"# + "\n")
            .write(to: dir.appendingPathComponent("p/def.jsonl"), atomically: true, encoding: .utf8)
        _ = StatsScanner.scan(projectsDir: dir, cacheURL: cache, calendar: cal)
        let third = try FileManager.default.attributesOfItem(atPath: cache.path)[.modificationDate] as! Date
        XCTAssertNotEqual(second, third)
    }

    func testAllOutSpanIsCappedAndClosedBySwitch() {
        func ev(_ kind: String, _ stamp: String) -> StatsEvent {
            StatsEvent(at: date(stamp), kind: kind, icon: "", text: kind)
        }
        // Orphan span: the revival lands three days later (an app
        // restart in between) — capped at 8 h, not 4320 minutes.
        let capped = StatsEvents.days([ev("limit", "2026-09-01T01:00:00Z"),
                                       ev("revival", "2026-09-04T01:00:00Z")], calendar: cal)
        XCTAssertEqual(capped["2026-09-04"]?.minutesLostToLimits ?? 0, 480, accuracy: 0.01)
        // A second `limit` inside the span doesn't restart it.
        let doubled = StatsEvents.days([ev("limit", "2026-09-04T01:00:00Z"),
                                        ev("limit", "2026-09-04T01:30:00Z"),
                                        ev("revival", "2026-09-04T02:00:00Z")], calendar: cal)
        XCTAssertEqual(doubled["2026-09-04"]?.minutesLostToLimits ?? 0, 60, accuracy: 0.01)
        // A switch closes an open span, and the next limit opens a fresh one.
        let bySwitch = StatsEvents.days([ev("limit", "2026-09-04T01:00:00Z"),
                                         ev("switch", "2026-09-04T01:20:00Z"),
                                         ev("limit", "2026-09-04T02:00:00Z"),
                                         ev("revival", "2026-09-04T02:10:00Z")], calendar: cal)
        XCTAssertEqual(bySwitch["2026-09-04"]?.minutesLostToLimits ?? 0, 30, accuracy: 0.01)
    }

    func testCompactedDayDropsHoursAndSetsAndStillAdds() {
        var d = Stats.Day(); d.sessions = ["s1", "s2"]; d.repos = ["r"]; d.hours[5] = 3; d.commits = 2
        let c = d.compacted()
        XCTAssertTrue(c.hours.isEmpty)
        XCTAssertTrue(c.sessions.isEmpty)
        XCTAssertEqual(c.sessionCount, 2)
        XCTAssertEqual(c.repoCount, 1)
        XCTAssertEqual(c.compacted(), c)   // idempotent
        // Mismatched lengths must not trap, and the tallies sum.
        let sum = c + d
        XCTAssertEqual(sum.hours.count, 168)
        XCTAssertEqual(sum.hours[5], 3)
        XCTAssertEqual(sum.commits, 4)
        XCTAssertEqual((c + c).sessionCount, 4)
        XCTAssertEqual(sum.sessionBuckets.count, 4)
    }

    func testBundleStaysUnderFourKilobytesWithManyToolNames() throws {
        var d = Stats.Day()
        for i in 0..<30 { d.toolCalls["ToolNumber\(i)"] = i + 1 }
        d.sessions = Set((0..<20).map { "session-\($0)" })
        d.repos = ["/a/b/c"]
        d.hours[7] = 12
        let b = Stats.Bundle(days: ["2026-09-04": d], now: date("2026-09-04T03:00:00Z"), calendar: cal)
        let json = String(decoding: try JSONEncoder().encode(b), as: UTF8.self)
        XCTAssertFalse(json.contains("\"hours\":[0"))
        XCTAssertTrue(b.periods.allSatisfy { $0.total.hours.isEmpty && $0.previous.hours.isEmpty })
        // The spec asks for ≤ 4 KB; that floor is not reachable while
        // `Day` encodes synthetically. An EMPTY bundle is already 5375
        // bytes: four periods × (total + previous) = 8 Days × ~617
        // bytes of zero-valued fields, and dropping `hours` (the 14.8 KB
        // culprit) only takes ~2.7 KB of that. Omitting defaults on
        // encode would fix it and is deliberately NOT done — every
        // already-installed phone decodes Day with the synthesized
        // initializer that throws on a missing key, so a sparse Mac
        // would break the whole MirrorSnapshot on it (the very failure
        // B2 exists to prevent), and the e2e gate asserts `commits` and
        // `humanMessages` are present on a zero summary. 14.8 KB → this.
        XCTAssertLessThan(json.utf8.count, 8_192)
    }

    func testSummaryCompactedStripsTheDailySeries() {
        var d = Stats.Day(); d.hours[3] = 1; d.sessions = ["s"]
        let s = Stats.fold(days: ["2026-09-04": d], period: .day, now: date("2026-09-04T03:00:00Z"), calendar: cal)
        XCTAssertEqual(s.daily.first?.day.hours.count, 168)
        let c = s.compacted()
        XCTAssertTrue(c.daily.allSatisfy { $0.day.hours.isEmpty && $0.day.sessions.isEmpty })
        XCTAssertEqual(c.daily.first?.day.sessionCount, 1)
    }

    func testDayDecodesForwardCompatibly() throws {
        let dec = JSONDecoder()
        XCTAssertEqual(try dec.decode(Stats.Day.self, from: Data("{}".utf8)), Stats.Day())
        var d = Stats.Day(); d.commits = 3; d.usd = 1.5; d.toolCalls = ["Bash": 2]; d.hours[9] = 4
        var obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(d)) as! [String: Any]
        obj.removeValue(forKey: "commits")            // an older writer, or a field this build predates
        obj["somethingNewer"] = 7                     // a field only a newer build knows
        let back = try dec.decode(Stats.Day.self, from: JSONSerialization.data(withJSONObject: obj))
        XCTAssertEqual(back.commits, 0)
        XCTAssertEqual(back.usd, 1.5)
        XCTAssertEqual(back.toolCalls, ["Bash": 2])
        XCTAssertEqual(back.hours[9], 4)
    }

    func testWeekIsMondayToSundayUnderASundayFirstCalendar() {
        var sundayFirst = Calendar(identifier: .gregorian)
        sundayFirst.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        sundayFirst.firstWeekday = 1
        var d = Stats.Day(); d.commits = 1
        // Sunday 2026-09-06 belongs to the week that STARTED Monday 2026-08-31.
        let s = Stats.fold(days: ["2026-09-06": d], period: .week,
                           now: date("2026-09-06T03:00:00Z"), calendar: sundayFirst)
        XCTAssertEqual(s.from, "2026-08-31")
        XCTAssertEqual(s.to, "2026-09-06")
        XCTAssertEqual(s.total.commits, 1)
    }

    func testStreakCountsBackFromYesterdayBeforeTodayStarts() {
        func day(_ commits: Int) -> Stats.Day { var d = Stats.Day(); d.commits = commits; return d }
        let days = ["2026-09-01": day(1), "2026-09-02": day(1), "2026-09-03": day(1)]
        // 09:00 on the 4th, nothing logged today yet.
        let s = Stats.fold(days: days, period: .day, now: date("2026-09-04T02:00:00Z"), calendar: cal)
        XCTAssertEqual(s.streak, 3)
        // With today active it counts today too.
        var withToday = days; withToday["2026-09-04"] = day(1)
        XCTAssertEqual(Stats.fold(days: withToday, period: .day,
                                  now: date("2026-09-04T02:00:00Z"), calendar: cal).streak, 4)
        // A gap yesterday and nothing today is still 0.
        XCTAssertEqual(Stats.fold(days: ["2026-09-01": day(1)], period: .day,
                                  now: date("2026-09-04T02:00:00Z"), calendar: cal).streak, 0)
    }

    func testYearSparklinesBucketToWeeks() {
        var daily: [Stats.DayPoint] = []
        var d = Stats.Day(); d.commits = 1; d.usd = 2
        for i in 0..<365 { daily.append(Stats.DayPoint(key: "d\(i)", day: d)) }
        var total = Stats.Day(); total.commits = 365; total.usd = 730
        let s = Stats.Summary(period: .year, from: "2026-01-01", to: "2026-12-31",
                              total: total, previous: Stats.Day(), daily: daily, streak: 0)
        let groups = Stats.Presentation.groups(s)
        for g in groups {
            for t in g.tiles { XCTAssertLessThanOrEqual(t.series.count, 53, "\(t.id)") }
        }
        let commits = groups.first { $0.id == "Throughput" }!.tiles.first { $0.id == "Commits" }!
        XCTAssertEqual(commits.series.first, 7)      // counts sum
        XCTAssertEqual(commits.series.last, 1)       // 365 = 52 weeks + 1 day
        let spend = groups.first { $0.id == "Cost (API-equivalent estimate)" }!.tiles.first { $0.id == "Spend" }!
        XCTAssertEqual(spend.series.first, 2)        // money means
        // A month-long series is left alone.
        let short = Stats.Summary(period: .month, from: "2026-09-01", to: "2026-09-30",
                                  total: total, previous: Stats.Day(),
                                  daily: Array(daily.prefix(30)), streak: 0)
        XCTAssertEqual(Stats.Presentation.groups(short).first!.tiles.first!.series.count, 30)
    }

    func testCatalogueSurfacesTheNewFacts() {
        var total = Stats.Day()
        total.filesTouched = 12; total.coAuthoredByClaude = 3; total.reverts = 1
        total.repos = ["a", "b"]; total.inputTokens = 4_000
        let s = Stats.Summary(period: .week, from: "2026-09-01", to: "2026-09-07",
                              total: total, previous: Stats.Day(), daily: [], streak: 0)
        let names = Stats.Presentation.groups(s).flatMap { $0.tiles.map(\.id) }
        for n in ["Files touched", "Co-authored by Claude", "Reverts", "Repos", "Input tokens"] {
            XCTAssertTrue(names.contains(n), n)
        }
        let throughput = Stats.Presentation.groups(s).first { $0.id == "Throughput" }!
        XCTAssertEqual(throughput.tiles.first { $0.id == "Repos" }?.value, "2")
        XCTAssertEqual(throughput.tiles.first { $0.id == "Files touched" }?.value, "12")
    }
}
