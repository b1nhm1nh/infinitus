import XCTest
@testable import InfinitusCore

/// #17 layer 2: the phone sends a reply or a decision into a session.
/// `FakeHost` is `SessionResumeTests`' scripted multiplexer, reused here
/// unchanged.
final class SessionInputTests: XCTestCase {
    private func record(socket: String = "") -> ClaudeSessionRecord {
        ClaudeSessionRecord(pid: 7, sessionId: "s1", cwd: "/repo", messagingSocketPath: socket)
    }

    private func host(_ screens: [String]) -> FakeHost {
        FakeHost(surfaces: [PtySurface(ref: "s1", tty: "ttys009")], screens: screens)
    }

    private func deliver(_ request: SessionInput.Request, hosts: [any PtyHost],
                         socket: String = "", socketSend: @escaping (ClaudeSessionRecord, String) -> Bool = { _, _ in false }
    ) -> SessionInput.Reply {
        SessionInput.deliver(request: request, record: record(socket: socket), hosts: hosts,
                             claudeDir: FileManager.default.temporaryDirectory,
                             ttyOfPid: { _ in "ttys009" }, ancestorsOf: { _ in [] },
                             socketSend: socketSend, sleep: { _ in })
    }

    // MARK: key validation

    func testUnsupportedKeyIsRejectedWithoutTouchingAHost() {
        let h = host(["> "])
        let reply = deliver(.init(kind: .key, text: "zz"), hosts: [h])
        XCTAssertEqual(reply, .init(outcome: "rejected", detail: "unsupported key"))
        XCTAssertEqual(h.commands, [])
    }

    func testKeyWhileRunningIsRunning() {
        let h = host(["Thinking… (esc to interrupt)"])
        let reply = deliver(.init(kind: .key, text: "1"), hosts: [h])
        XCTAssertEqual(reply, .init(outcome: "running"))
    }

    func testKeyEnterSendsAnEmptyLine() {
        let h = host(["some menu"])
        let reply = deliver(.init(kind: .key, text: "enter"), hosts: [h])
        XCTAssertEqual(reply, .init(outcome: "delivered", channel: "pty"))
        XCTAssertEqual(h.commands, ["read s1", "line s1 ", "read s1"])
    }

    func testKeyEscSendsEscape() {
        let h = host(["some menu"])
        let reply = deliver(.init(kind: .key, text: "esc"), hosts: [h])
        XCTAssertEqual(reply, .init(outcome: "delivered", channel: "pty"))
        XCTAssertEqual(h.commands, ["read s1", "esc s1", "read s1"])
    }

    func testKeyDigitTypesTheDigit() {
        let h = host(["some menu"])
        let reply = deliver(.init(kind: .key, text: "1"), hosts: [h])
        XCTAssertEqual(reply, .init(outcome: "delivered", channel: "pty"))
        XCTAssertEqual(h.commands, ["read s1", "line s1 1", "read s1"])
    }

    func testKeyWithNoSurfaceReportsNoSurface() {
        let reply = deliver(.init(kind: .key, text: "y"), hosts: [])
        XCTAssertEqual(reply, .init(outcome: "noSurface"))
    }

    // MARK: message validation

    func testEmptyOrOverlongOrControlCharMessageIsRejected() {
        let h = host(["> "])
        XCTAssertEqual(deliver(.init(kind: .message, text: ""), hosts: [h]).outcome, "rejected")
        XCTAssertEqual(deliver(.init(kind: .message, text: String(repeating: "x", count: 4001)),
                               hosts: [h]).outcome, "rejected")
        XCTAssertEqual(deliver(.init(kind: .message, text: "hi\tthere"), hosts: [h]).outcome, "rejected")
        // A newline is fine.
        XCTAssertEqual(h.commands, [])
    }

    func testMessageDeliveredViaPty() {
        let h = host(["> ", "> hi there"])
        let reply = deliver(.init(kind: .message, text: "hi there"), hosts: [h])
        XCTAssertEqual(reply, .init(outcome: "delivered", channel: "pty"))
    }

    func testMessageWithASocketIsNeverTyped() {
        let h = host(["> ", "> hi there"])
        let reply = deliver(.init(kind: .message, text: "hi\nthere"), hosts: [h],
                            socket: "/tmp/x.sock", socketSend: { _, text in text == "hi\nthere" })
        XCTAssertEqual(reply, .init(outcome: "delivered", channel: "socket"))
        XCTAssertEqual(h.commands, [], "line breaks kept, terminal untouched")
    }

    func testMessageGoesToSocketWhenNoSurface() {
        var sent: (ClaudeSessionRecord, String)?
        let reply = deliver(.init(kind: .message, text: "hi there"), hosts: [],
                            socket: "/tmp/x.sock", socketSend: { record, text in
            sent = (record, text)
            return true
        })
        XCTAssertEqual(reply, .init(outcome: "delivered", channel: "socket"))
        XCTAssertEqual(sent?.1, "hi there")
    }

    func testMessageWhileRunningWithNoUsableSocketReportsRunning() {
        let running = host(["Thinking… (esc to interrupt)"])
        // Socket also unavailable: outcome reflects the pty's own state.
        let reply = deliver(.init(kind: .message, text: "hi there"), hosts: [running],
                            socket: "/tmp/x.sock", socketSend: { _, _ in false })
        XCTAssertEqual(reply, .init(outcome: "running"))
    }

    func testMessageWhileRunningButSocketSucceedsIsStillDelivered() {
        let running = host(["Thinking… (esc to interrupt)"])
        let reply = deliver(.init(kind: .message, text: "hi there"), hosts: [running],
                            socket: "/tmp/x.sock", socketSend: { _, _ in true })
        XCTAssertEqual(reply, .init(outcome: "delivered", channel: "socket"))
    }

    func testMessageWithNoSurfaceAndNoSocketPathIsNoChannel() {
        let reply = deliver(.init(kind: .message, text: "hi there"), hosts: [])
        XCTAssertEqual(reply, .init(outcome: "noChannel"))
    }

    func testMessageWithNoSurfaceButUnsendableSocketIsNoSurface() {
        let reply = deliver(.init(kind: .message, text: "hi there"), hosts: [],
                            socket: "/tmp/x.sock", socketSend: { _, _ in false })
        XCTAssertEqual(reply, .init(outcome: "noSurface"))
    }

    // MARK: wire round-trip

    func testRequestAndReplyRoundTripJSON() throws {
        let request = SessionInput.Request(kind: .message, text: "yes please")
        let requestData = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(SessionInput.Request.self, from: requestData), request)

        let reply = SessionInput.Reply(outcome: "delivered", channel: "pty", detail: nil)
        let replyData = try JSONEncoder().encode(reply)
        XCTAssertEqual(try JSONDecoder().decode(SessionInput.Reply.self, from: replyData), reply)
    }
}
