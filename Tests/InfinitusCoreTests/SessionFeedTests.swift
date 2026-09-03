import XCTest
@testable import InfinitusCore

final class SessionFeedTests: XCTestCase {
    func testUserAssistantTextAndBashToolInOrder() {
        let lines = [
            #"{"type":"user","timestamp":"2026-09-01T10:00:00.000Z","message":{"content":"fix the build"}}"#,
            #"{"type":"assistant","timestamp":"2026-09-01T10:00:01.000Z","message":{"content":[{"type":"text","text":"Looking into it."}]}}"#,
            #"{"type":"assistant","timestamp":"2026-09-01T10:00:02.000Z","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"swift build"}}]}}"#,
        ]
        let items = SessionFeedReader.parse(lines: lines, limit: 30)
        XCTAssertEqual(items.map(\.kind), [.user, .assistant, .tool])
        XCTAssertEqual(items[0].text, "fix the build")
        XCTAssertEqual(items[1].text, "Looking into it.")
        XCTAssertEqual(items[2].toolName, "Bash")
        XCTAssertEqual(items[2].text, "swift build")
    }

    /// An assistant text block immediately followed by a real user prompt
    /// (or nothing) is the final answer of its turn; one still followed
    /// by more assistant work (even across bookkeeping entries like
    /// `turn_duration`) is not.
    func testResultKindOnlyAtTurnEnd() {
        let midTurn = [
            #"{"type":"assistant","timestamp":"2026-09-01T10:00:00.000Z","message":{"content":[{"type":"text","text":"About to run tests."}]}}"#,
            #"{"type":"assistant","timestamp":"2026-09-01T10:00:01.000Z","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"swift test"}}]}}"#,
        ]
        XCTAssertEqual(SessionFeedReader.parse(lines: midTurn, limit: 30).first?.kind, .assistant)

        let turnEnd = [
            #"{"type":"assistant","timestamp":"2026-09-01T10:00:00.000Z","message":{"content":[{"type":"text","text":"All green."}]}}"#,
            #"{"type":"system","subtype":"turn_duration"}"#,
            #"{"type":"user","timestamp":"2026-09-01T10:00:02.000Z","message":{"content":"thanks"}}"#,
        ]
        let items = SessionFeedReader.parse(lines: turnEnd, limit: 30)
        XCTAssertEqual(items.first?.kind, .result)
        XCTAssertEqual(items.last?.kind, .user)

        // Last entry in the whole tail, nothing follows at all.
        let atEOF = [#"{"type":"assistant","timestamp":"2026-09-01T10:00:00.000Z","message":{"content":[{"type":"text","text":"Done."}]}}"#]
        XCTAssertEqual(SessionFeedReader.parse(lines: atEOF, limit: 30).first?.kind, .result)
    }

    func testAskUserQuestionCarriesOptions() {
        let line = """
        {"type":"assistant","timestamp":"2026-09-01T10:00:00.000Z","message":{"content":[\
        {"type":"tool_use","id":"t1","name":"AskUserQuestion","input":{"questions":[\
        {"question":"Which approach?","options":[{"label":"A"},{"label":"B"}]}]}}]}}
        """
        let items = SessionFeedReader.parse(lines: [line], limit: 30)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].kind, .question)
        XCTAssertEqual(items[0].text, "Which approach?")
        XCTAssertEqual(items[0].options, ["A", "B"])
    }

    func testToolResultNoiseDroppedExceptErrors() {
        let lines = [
            #"{"type":"assistant","timestamp":"2026-09-01T10:00:00.000Z","message":{"content":[{"type":"tool_use","id":"t1","name":"Grep","input":{"pattern":"foo"}}]}}"#,
            #"{"type":"user","timestamp":"2026-09-01T10:00:01.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"a\nb","is_error":false}]}}"#,
            #"{"type":"assistant","timestamp":"2026-09-01T10:00:02.000Z","message":{"content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"cat missing"}}]}}"#,
            #"{"type":"user","timestamp":"2026-09-01T10:00:03.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":"no such file","is_error":true}]}}"#,
        ]
        let items = SessionFeedReader.parse(lines: lines, limit: 30)
        // The clean tool_result is dropped; the two calls collapse into one
        // mixed chip; the error becomes its own item after it.
        XCTAssertEqual(items.map(\.kind), [.tool, .tool])
        XCTAssertEqual(items[0].text, "cat missing (\u{00d7}2)")
        XCTAssertEqual(items[0].toolName, "Grep, Bash")
        XCTAssertEqual(items[1].text, "error: no such file")
        XCTAssertEqual(items[1].toolName, "Bash")
    }

    /// Same tool name repeated collapses into a count — but never across
    /// an error result, which must stay visible.
    func testErrorNeverCollapsesIntoASameNameRun() {
        let lines = [
            #"{"type":"assistant","timestamp":"2026-09-01T10:00:00.000Z","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}"#,
            #"{"type":"assistant","timestamp":"2026-09-01T10:00:01.000Z","message":{"content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"cat missing"}}]}}"#,
            #"{"type":"user","timestamp":"2026-09-01T10:00:02.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":"no such file","is_error":true}]}}"#,
            #"{"type":"assistant","timestamp":"2026-09-01T10:00:03.000Z","message":{"content":[{"type":"tool_use","id":"t3","name":"Bash","input":{"command":"pwd"}}]}}"#,
        ]
        let items = SessionFeedReader.parse(lines: lines, limit: 30)
        XCTAssertEqual(items.map(\.kind), [.tool, .tool, .tool])
        // "ls" then "cat missing" collapse (same name, no error between).
        XCTAssertEqual(items[0].text, "cat missing (\u{00d7}2)")
        XCTAssertEqual(items[1].text, "error: no such file")
        // The run resets after the error: "pwd" starts fresh, uncollapsed.
        XCTAssertEqual(items[2].text, "pwd")
    }

    func testConsecutiveSameToolCollapsesWithCount() {
        func read(_ path: String) -> String {
            #"{"type":"assistant","timestamp":"2026-09-01T10:00:00.000Z","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"\#(path)"}}]}}"#
        }
        let items = SessionFeedReader.parse(lines: [read("/a/One.swift"), read("/a/Two.swift"), read("/a/Three.swift")],
                                            limit: 30)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].kind, .tool)
        XCTAssertEqual(items[0].toolName, "Read")
        XCTAssertEqual(items[0].text, "Three.swift (\u{00d7}3)")
    }

    func testConsecutiveMixedToolsCollapseIntoOneChip() {
        let lines = [
            #"{"type":"assistant","timestamp":"2026-09-01T10:00:00.000Z","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}"#,
            #"{"type":"assistant","timestamp":"2026-09-01T10:00:01.000Z","message":{"content":[{"type":"tool_use","id":"t2","name":"Read","input":{"file_path":"/a/One.swift"}}]}}"#,
            #"{"type":"assistant","timestamp":"2026-09-01T10:00:02.000Z","message":{"content":[{"type":"tool_use","id":"t3","name":"Bash","input":{"command":"pwd"}}]}}"#,
            #"{"type":"assistant","timestamp":"2026-09-01T10:00:03.000Z","message":{"content":[{"type":"text","text":"Done looking."}]}}"#,
        ]
        let items = SessionFeedReader.parse(lines: lines, limit: 30)
        XCTAssertEqual(items.map(\.kind), [.tool, .result])   // last text = turn end
        XCTAssertEqual(items[0].toolName, "Bash, Read")
        XCTAssertEqual(items[0].text, "pwd (\u{00d7}3)")
    }

    func testMidTurnQueuedPromptShowsAsUserMessage() {
        let lines = [
            #"{"type":"assistant","timestamp":"2026-09-01T10:00:00.000Z","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}"#,
            #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-09-01T10:00:01.000Z","content":"also check the tests"}"#,
            #"{"type":"attachment","timestamp":"2026-09-01T10:00:01.000Z","attachment":{"type":"queued_command","prompt":"also check the tests","commandMode":"prompt","origin":{"kind":"human"}}}"#,
            #"{"type":"attachment","timestamp":"2026-09-01T10:00:02.000Z","attachment":{"type":"total_tokens_reminder","text":"<total_tokens>1</total_tokens>"}}"#,
        ]
        let items = SessionFeedReader.parse(lines: lines, limit: 30)
        XCTAssertEqual(items.map(\.kind), [.tool, .user])
        XCTAssertEqual(items[1].text, "also check the tests")
    }

    func testCrossSessionMessageShowsSenderAndBody() {
        let raw = "<cross-session-message from=\"uds:/tmp/x.sock\" from-name=\"Infinitus2\" from-mode=\"bypass\">\nmerge e2 at abc123\n</cross-session-message>"
        XCTAssertEqual(SessionFeedReader.presentableUserText(raw), "Infinitus2: merge e2 at abc123")
        XCTAssertNil(SessionFeedReader.presentableUserText("<system-reminder>x</system-reminder>"))
        XCTAssertEqual(SessionFeedReader.presentableUserText("  hi  "), "hi")
    }

    func testAdjacentAssistantTextBlocksShareOneBubble() {
        let lines = [
            #"{"type":"assistant","timestamp":"2026-09-01T10:00:00.000Z","message":{"content":[{"type":"text","text":"First part."}]}}"#,
            #"{"type":"assistant","timestamp":"2026-09-01T10:00:01.000Z","message":{"content":[{"type":"text","text":"Second part."}]}}"#,
            #"{"type":"assistant","timestamp":"2026-09-01T10:00:02.000Z","message":{"content":[{"type":"text","text":"Last part."}]}}"#,
        ]
        let items = SessionFeedReader.parse(lines: lines, limit: 30)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].kind, .result)
        XCTAssertEqual(items[0].text, "First part.\n\nSecond part.\n\nLast part.")
    }

    func testAgentRowsAreFilledFromTheSubagentsDir() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("feed-agents-\(UUID().uuidString)")
        let transcript = root.appendingPathComponent("s1.jsonl")
        let sub = root.appendingPathComponent("s1/subagents")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try #"{"agentType":"coder","description":"port the thing","toolUseId":"toolu_A"}"#
            .write(to: sub.appendingPathComponent("agent-abc.meta.json"), atomically: true, encoding: .utf8)
        try [
            #"{"type":"user","timestamp":"2026-09-01T10:00:00.000Z","isSidechain":true,"message":{"content":"do it"}}"#,
            #"{"type":"assistant","timestamp":"2026-09-01T10:00:01.000Z","isSidechain":true,"message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"swift build"}}]}}"#,
            #"{"type":"assistant","timestamp":"2026-09-01T10:00:02.000Z","isSidechain":true,"message":{"content":[{"type":"tool_use","id":"t2","name":"Edit","input":{"file_path":"/a/B.swift"}}]}}"#,
            #"{"type":"assistant","timestamp":"2026-09-01T10:00:03.000Z","isSidechain":true,"message":{"content":[{"type":"text","text":"Done."}]}}"#,
        ].joined(separator: "\n").write(to: sub.appendingPathComponent("agent-abc.jsonl"), atomically: true, encoding: .utf8)
        let main = [
            #"{"type":"assistant","timestamp":"2026-09-01T10:00:00.000Z","message":{"content":[{"type":"tool_use","id":"toolu_A","name":"Agent","input":{"description":"port the thing","subagent_type":"coder","prompt":"…"}}]}}"#,
            #"{"type":"assistant","timestamp":"2026-09-01T10:00:00.500Z","message":{"content":[{"type":"tool_use","id":"toolu_B","name":"Bash","input":{"command":"ls"}}]}}"#,
        ]
        let items = SessionFeedReader.attachAgents(SessionFeedReader.parse(lines: main, limit: 30),
                                                   transcript: transcript)
        XCTAssertEqual(items.map(\.kind), [.agent, .tool])
        let agent = try XCTUnwrap(items[0].agent)
        XCTAssertEqual(agent.type, "coder")
        XCTAssertEqual(agent.toolCalls, 2)
        XCTAssertEqual(agent.lastTool, "Edit · B.swift")
        XCTAssertFalse(agent.running)   // ended with text (and the file is old)
        // Wire: toolUseId stays private, agent rides along.
        let data = try JSONEncoder().encode(items[0])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("toolUseId"))
        XCTAssertEqual(try JSONDecoder().decode(SessionFeedItem.self, from: data).agent?.toolCalls, 2)
    }

    func testLimitReturnsOnlyNewestItems() {
        let lines = (0..<5).map { i in
            #"{"type":"user","timestamp":"2026-09-01T10:00:0\#(i).000Z","message":{"content":"msg \#(i)"}}"#
        }
        let items = SessionFeedReader.parse(lines: lines, limit: 2)
        XCTAssertEqual(items.map(\.text), ["msg 3", "msg 4"])
    }

    func testFinalizeMarksOpenToolAsPermissionWhenWaiting() {
        let items = [SessionFeedItem(kind: .user, text: "go"),
                     SessionFeedItem(kind: .tool, text: "rm -rf build", toolName: "Bash")]
        let (finalized, waiting) = SessionFeedReader.finalize(items: items, status: "waiting")
        XCTAssertTrue(waiting)
        XCTAssertEqual(finalized.last?.kind, .permission)
        XCTAssertEqual(finalized.last?.toolName, "Bash")

        let (busyFinalized, busyWaiting) = SessionFeedReader.finalize(items: items, status: "busy")
        XCTAssertFalse(busyWaiting)
        XCTAssertEqual(busyFinalized.last?.kind, .tool)
    }

    func testFinalizeWaitingOnQuestionEvenWithoutRecordStatus() {
        let items = [SessionFeedItem(kind: .question, text: "Which approach?", options: ["A", "B"])]
        let (_, waiting) = SessionFeedReader.finalize(items: items, status: "busy")
        XCTAssertTrue(waiting)
    }
}
