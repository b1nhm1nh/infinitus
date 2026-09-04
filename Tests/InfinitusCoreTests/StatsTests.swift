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
        XCTAssertEqual(d.waitingSeconds, 3600, accuracy: 0.5) // turn end 01:00:11 → phone message 02:00:11
        XCTAssertEqual(d.longestUnattended, 4)              // Bash, Bash, Agent, AskUserQuestion between the two human messages
        XCTAssertEqual(d.hours.reduce(0, +), 10)            // every entry lands in a slot
        XCTAssertEqual(e.cwd, "/r/a")
    }

    func testWaitingGapIsCappedAtEightHours() {
        var e = StatsScanner.FileEntry()
        StatsScanner.ingest(entry(#"{"type":"assistant","timestamp":"2026-09-01T01:00:00.000Z","message":{"id":"m1","model":"claude-opus-4-5-20250805","usage":{"input_tokens":1,"output_tokens":1},"content":[{"type":"text","text":"done"}]}}"#), sessionID: "s", into: &e, calendar: cal)
        StatsScanner.ingest(entry(#"{"type":"user","timestamp":"2026-09-02T01:00:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"back"}}"#), sessionID: "s", into: &e, calendar: cal)
        XCTAssertEqual(e.days.values.map(\.waitingSeconds).reduce(0, +), 8 * 3600, accuracy: 0.5)
    }
}
