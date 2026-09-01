import XCTest
@testable import CswapCore

final class SessionProgressTests: XCTestCase {
    func testTodosCounting() {
        let line = """
        {"type":"assistant","timestamp":"2026-09-01T10:00:00.000Z","message":{"content":[\
        {"type":"tool_use","name":"TodoWrite","input":{"todos":[\
        {"content":"a","status":"completed","activeForm":"Did a"},\
        {"content":"b","status":"in_progress","activeForm":"Doing b"},\
        {"content":"c","status":"pending","activeForm":"Do c"}]}}]}}
        """
        let progress = SessionProgress.parse(lines: [line])
        XCTAssertEqual(progress.todos?.done, 1)
        XCTAssertEqual(progress.todos?.total, 3)
        XCTAssertEqual(progress.todos?.activeForm, "Doing b")
    }

    func testTodosNilWhenNoneInTail() {
        let line = """
        {"type":"assistant","timestamp":"2026-09-01T10:00:00.000Z","message":{"content":[\
        {"type":"text","text":"just talking"}]}}
        """
        let progress = SessionProgress.parse(lines: [line])
        XCTAssertNil(progress.todos)
    }

    func testTodosActiveFormNilWhenNoneInProgress() {
        let line = """
        {"type":"assistant","timestamp":"2026-09-01T10:00:00.000Z","message":{"content":[\
        {"type":"tool_use","name":"TodoWrite","input":{"todos":[\
        {"content":"a","status":"completed","activeForm":"Did a"},\
        {"content":"b","status":"pending","activeForm":"Do b"}]}}]}}
        """
        let progress = SessionProgress.parse(lines: [line])
        XCTAssertEqual(progress.todos?.done, 1)
        XCTAssertEqual(progress.todos?.total, 2)
        XCTAssertNil(progress.todos?.activeForm)
    }

    func testNowDoingForReadEditWriteBashGrepAndOtherTools() {
        func line(_ name: String, _ input: String) -> String {
            """
            {"type":"assistant","timestamp":"2026-09-01T10:00:00.000Z",\
            "message":{"content":[{"type":"tool_use","name":"\(name)","input":\(input)}]}}
            """
        }
        XCTAssertEqual(SessionProgress.parse(lines: [line("Read", #"{"file_path":"/a/b/Foo.swift"}"#)]).nowDoing,
                       "Reading Foo.swift")
        XCTAssertEqual(SessionProgress.parse(lines: [line("Edit", #"{"file_path":"/a/b/Foo.swift"}"#)]).nowDoing,
                       "Editing Foo.swift")
        XCTAssertEqual(SessionProgress.parse(lines: [line("Write", #"{"file_path":"/a/b/Foo.swift"}"#)]).nowDoing,
                       "Writing Foo.swift")
        XCTAssertEqual(SessionProgress.parse(lines: [line("Bash", #"{"command":"swift test --filter X"}"#)]).nowDoing,
                       "Running swift")
        let longPattern = String(repeating: "x", count: 60)
        let grep = SessionProgress.parse(lines: [line("Grep", #"{"pattern":"\#(longPattern)"}"#)]).nowDoing
        XCTAssertEqual(grep, "Searching " + String(longPattern.prefix(40)))
        XCTAssertEqual(SessionProgress.parse(lines: [line("WebFetch", "{}")]).nowDoing, "WebFetch")
    }

    func testNowDoingTextFallbackFirstLineTruncated() {
        // "\n" here is a literal JSON escape (two chars) separating the two
        // lines inside the string value, not a raw newline.
        let longLine = String(repeating: "a", count: 120)
        let line = """
        {"type":"assistant","timestamp":"2026-09-01T10:00:00.000Z",\
        "message":{"content":[{"type":"text","text":"\(longLine)\\nsecond line"}]}}
        """
        let progress = SessionProgress.parse(lines: [line])
        XCTAssertEqual(progress.nowDoing, String(repeating: "a", count: 80))
    }

    func testTitleExtraction() {
        let lines = [
            """
            {"type":"summary","summary":"Fix the flaky test"}
            """,
            """
            {"type":"assistant","timestamp":"2026-09-01T10:00:00.000Z",\
            "message":{"content":[{"type":"text","text":"working"}]}}
            """
        ]
        XCTAssertEqual(SessionProgress.parse(lines: lines).title, "Fix the flaky test")
    }

    func testTornTailToleratesGarbageFirstLine() {
        let lines = [
            #"path":"foo"},"garbage":{"#,
            """
            {"type":"summary","summary":"Recovered fine"}
            """,
            """
            {"type":"assistant","timestamp":"2026-09-01T10:00:00.000Z",\
            "message":{"content":[{"type":"text","text":"hello"}],"usage":{"output_tokens":7}}}
            """
        ]
        let progress = SessionProgress.parse(lines: lines)
        XCTAssertEqual(progress.title, "Recovered fine")
        XCTAssertEqual(progress.outputTokens, 7)
        XCTAssertEqual(progress.nowDoing, "hello")
    }

    func testOutputTokenSumming() {
        let lines = [
            """
            {"type":"assistant","timestamp":"2026-09-01T10:00:00.000Z",\
            "message":{"content":[{"type":"text","text":"one"}],"usage":{"output_tokens":10}}}
            """,
            """
            {"type":"assistant","timestamp":"2026-09-01T10:00:01.000Z",\
            "message":{"content":[{"type":"text","text":"two"}],"usage":{"output_tokens":5}}}
            """
        ]
        XCTAssertEqual(SessionProgress.parse(lines: lines).outputTokens, 15)
    }

    func testRetryingTrueWhenLastDecisiveEntryIsApiError() {
        let lines = [
            """
            {"type":"user","timestamp":"2026-09-01T10:00:00.000Z",\
            "message":{"content":[{"type":"text","text":"do it"}]}}
            """,
            """
            {"type":"assistant","timestamp":"2026-09-01T10:00:01.000Z","isApiErrorMessage":true,\
            "error":"overloaded_error","message":{"content":[{"type":"text","text":"retrying..."}]}}
            """
        ]
        XCTAssertTrue(SessionProgress.parse(lines: lines).retrying)
    }

    func testRetryingFalseWhenLastDecisiveEntryIsNormal() {
        let lines = [
            """
            {"type":"assistant","timestamp":"2026-09-01T10:00:00.000Z",\
            "message":{"content":[{"type":"text","text":"all good"}]}}
            """
        ]
        XCTAssertFalse(SessionProgress.parse(lines: lines).retrying)
    }

    func testLastActivityAtIsNewestEntryTimestamp() {
        let lines = [
            """
            {"type":"assistant","timestamp":"2026-09-01T10:00:00.000Z",\
            "message":{"content":[{"type":"text","text":"first"}]}}
            """,
            """
            {"type":"assistant","timestamp":"2026-09-01T10:05:00.000Z",\
            "message":{"content":[{"type":"text","text":"second"}]}}
            """
        ]
        XCTAssertEqual(SessionProgress.parse(lines: lines).lastActivityAt,
                       UsageHistory.parseISO("2026-09-01T10:05:00.000Z"))
    }

    func testReadConvenienceReadsTailFromDisk() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sp-\(UUID().uuidString)")
        let cwd = "/tmp/proj"
        let sid = "abc"
        let tdir = dir.appendingPathComponent("projects/-tmp-proj")
        try FileManager.default.createDirectory(at: tdir, withIntermediateDirectories: true)
        let entry = """
        {"type":"assistant","timestamp":"2026-09-01T10:00:00.000Z",\
        "message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/a/Foo.swift"}}],\
        "usage":{"output_tokens":3}}}
        """
        try (entry + "\n").write(to: tdir.appendingPathComponent("\(sid).jsonl"),
                                 atomically: true, encoding: .utf8)
        let progress = SessionProgress.read(sessionId: sid, cwd: cwd, claudeDir: dir)
        XCTAssertEqual(progress.nowDoing, "Reading Foo.swift")
        XCTAssertEqual(progress.outputTokens, 3)
        XCTAssertEqual(progress.lastActivityAt, UsageHistory.parseISO("2026-09-01T10:00:00.000Z"))
    }

    func testMatchPairsSessionsToRecordsByPid() {
        let sessions = [SessionDetail(pid: 1, cwd: "/a", status: "busy", kind: "interactive", startedAt: 0),
                        SessionDetail(pid: 2, cwd: "/b", status: "idle", kind: "interactive", startedAt: 0)]
        let records = [ClaudeSessionRecord(pid: 1, sessionId: "s1", cwd: "/a"),
                       ClaudeSessionRecord(pid: 2, sessionId: "s2", cwd: "/b")]
        let pairs = SessionProgress.match(sessions: sessions, records: records)
        XCTAssertEqual(pairs.count, 2)
        XCTAssertEqual(pairs.first { $0.session.pid == 1 }?.record.sessionId, "s1")
        XCTAssertEqual(pairs.first { $0.session.pid == 2 }?.record.sessionId, "s2")
    }

    func testMatchIgnoresUnmatchedSessions() {
        let sessions = [SessionDetail(pid: 1, cwd: "/a", status: "busy", kind: "interactive", startedAt: 0),
                        SessionDetail(pid: 99, cwd: "/z", status: "busy", kind: "interactive", startedAt: 0)]
        let records = [ClaudeSessionRecord(pid: 1, sessionId: "s1", cwd: "/a")]
        let pairs = SessionProgress.match(sessions: sessions, records: records)
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs.first?.session.pid, 1)
    }

    func testSessionPanelRowMapsRepoAndProgressFields() {
        let record = ClaudeSessionRecord(pid: 1, sessionId: "s1",
                                         cwd: "/Users/x/death/limitless", status: "busy")
        let progress = SessionProgress(
            nowDoing: "Reading Foo.swift",
            todos: .init(done: 1, total: 3, activeForm: "Doing b"),
            retrying: false)
        let row = SessionPanelRow.make(record: record, progress: progress)
        XCTAssertEqual(row.repo, "limitless")
        XCTAssertEqual(row.status, "busy")
        XCTAssertEqual(row.nowDoing, "Reading Foo.swift")
        XCTAssertEqual(row.todosDone, 1)
        XCTAssertEqual(row.todosTotal, 3)
        XCTAssertEqual(row.activeForm, "Doing b")
        XCTAssertFalse(row.retrying)
    }

    func testSessionPanelRowQuietMinutesThresholdAt120Seconds() {
        let record = ClaudeSessionRecord(pid: 1, sessionId: "s1", cwd: "/a/b", status: "waiting")
        let now = Date()
        let justUnder = SessionProgress(lastActivityAt: now.addingTimeInterval(-119))
        XCTAssertNil(SessionPanelRow.make(record: record, progress: justUnder, now: now).quietMinutes)
        let over = SessionProgress(lastActivityAt: now.addingTimeInterval(-181))
        XCTAssertEqual(SessionPanelRow.make(record: record, progress: over, now: now).quietMinutes, 3)
    }
}
