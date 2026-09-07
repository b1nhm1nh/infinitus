import XCTest
import InfinitusCore
@testable import InfinitusWin

/// #151 on the daemon: `POST /sessions/start` and owned-first input.
/// Pure route dispatch — no child spawn. The POSIX fake-claude suite
/// (`OwnedSessionsProcessTests`) is skipped on Windows; this file covers
/// the wiring those tests never see.
final class OwnedSessionsRouteTests: XCTestCase {
    static let token = "TESTTOKENTESTTOKENTESTTO"

    /// Stubbed start answers the same JSON shape the Mac encodes.
    func testStartRouteEncodesStubbedReply() throws {
        try DaemonHarness.scratch { dir in
            let handler = self.handler(claudeDir: dir, startOverride: { req in
                XCTAssertEqual(req.cwd, "D:\\w\\synthetic")
                XCTAssertEqual(req.headless, true)
                return SessionStart.Reply(outcome: "started", host: "owned", pid: 4242)
            })
            let body = try JSONEncoder().encode(
                SessionStart.Request(cwd: "D:\\w\\synthetic", headless: true))
            let reply = try self.decodeStart(handler(self.post(SessionStart.path, body: body)))
            XCTAssertEqual(reply.outcome, "started")
            XCTAssertEqual(reply.host, "owned")
            XCTAssertEqual(reply.pid, 4242)
        }
    }

    /// A nil locator is the Mac's "claude isn't on PATH" failed reply, not
    /// a 503 — the listener is up; claude just isn't there.
    func testNilLocatorAnswersFailed() throws {
        try DaemonHarness.scratch { dir in
            let handler = self.handler(claudeDir: dir, locate: { nil })
            let body = try JSONEncoder().encode(
                SessionStart.Request(cwd: "D:\\w\\synthetic", headless: true))
            let reply = try self.decodeStart(handler(self.post(SessionStart.path, body: body)))
            XCTAssertEqual(reply.outcome, "failed")
            XCTAssertTrue(reply.detail?.contains("claude isn't on PATH") == true, reply.detail ?? "")
            XCTAssertTrue(reply.detail?.contains("2.1.259") == true, reply.detail ?? "")
        }
    }

    /// Windows has no terminal host: an explicit `headless: false` is
    /// `noHost`, never a spawn.
    func testHeadlessFalseIsNoHost() throws {
        try DaemonHarness.scratch { dir in
            let flag = Flag()
            let handler = self.handler(claudeDir: dir, locate: { flag.value = true; return nil })
            let body = try JSONEncoder().encode(
                SessionStart.Request(cwd: "D:\\w\\synthetic", headless: false))
            let reply = try self.decodeStart(handler(self.post(SessionStart.path, body: body)))
            XCTAssertEqual(reply.outcome, "noHost")
            XCTAssertFalse(flag.value, "a noHost start must not locate claude")
        }
    }

    /// Owned hit: `deliver` answers stdin and the pipe is never tried.
    func testInputOwnedHitReturnsStdin() throws {
        try DaemonHarness.scratch { dir in
            try self.writeSession(pid: SelfProcess.pid, pipe: "", to: dir)
            let handler = self.handler(claudeDir: dir, deliverOverride: { _, record in
                XCTAssertEqual(record.pid, SelfProcess.pid)
                return SessionInput.Reply(outcome: "delivered", channel: "stdin")
            })
            // Empty pipe path: if the owned hook is skipped, deliver cannot
            // claim channel stdin.
            let body = try JSONEncoder().encode(SessionInput.Request(kind: .message, text: "hi"))
            let reply = try self.decodeInput(handler(self.post("/sessions/\(SelfProcess.pid)/input", body: body)))
            XCTAssertEqual(reply.outcome, "delivered")
            XCTAssertEqual(reply.channel, "stdin")
        }
    }

    /// Owned miss (`deliver` returns nil): fall through to the named pipe.
    /// No server is listening, so the pipe path answers honestly rather
    /// than stdin.
    func testInputOwnedMissFallsToPipe() throws {
        try DaemonHarness.scratch { dir in
            try self.writeSession(pid: SelfProcess.pid, pipe: "\\\\.\\pipe\\LOCAL\\cc-msg-missing", to: dir)
            let handler = self.handler(claudeDir: dir, deliverOverride: { _, _ in nil })
            let body = try JSONEncoder().encode(SessionInput.Request(kind: .message, text: "hi"))
            let reply = try self.decodeInput(handler(self.post("/sessions/\(SelfProcess.pid)/input", body: body)))
            XCTAssertNotEqual(reply.channel, "stdin")
            XCTAssertNotEqual(reply.outcome, "delivered")
        }
    }

    /// A garbage start body is 400, not a spawn.
    func testStartBadBodyIs400() throws {
        try DaemonHarness.scratch { dir in
            let handler = self.handler(claudeDir: dir)
            let parsed = try XCTUnwrap(MirrorTransport.parseResponse(
                handler(self.post(SessionStart.path, body: Data("not-json".utf8)))))
            XCTAssertEqual(parsed.status, 400)
        }
    }

    /// Spawn tests stay skipped here — the fake is a POSIX shell script.
    func testSpawnSkippedOnWindows() throws {
        try XCTSkipIf(true, "spawns a POSIX shell fake")
    }

    private final class Flag: @unchecked Sendable { var value = false }

    // MARK: plumbing

    private func handler(claudeDir: URL,
                         locate: @escaping @Sendable () -> String? = { nil },
                         startOverride: (@Sendable (SessionStart.Request) -> SessionStart.Reply)? = nil,
                         deliverOverride: (@Sendable (SessionInput.Request, ClaudeSessionRecord) -> SessionInput.Reply?)? = nil)
        -> (MirrorTransport.Request) -> Data {
        Routes.handler(claudeDir: claudeDir, snapshot: SnapshotCache(claudeDir: claudeDir),
                       token: Self.token, owned: OwnedSessionsBox(),
                       locate: locate, startOverride: startOverride,
                       deliverOverride: deliverOverride)
    }

    private func post(_ path: String, body: Data) -> MirrorTransport.Request {
        MirrorTransport.Request(
            method: "POST", target: path,
            headers: ["authorization": "Bearer \(Self.token)",
                      "content-length": "\(body.count)"],
            body: body)
    }

    private func decodeStart(_ response: Data) throws -> SessionStart.Reply {
        let parsed = try XCTUnwrap(MirrorTransport.parseResponse(response))
        XCTAssertEqual(parsed.status, 200)
        return try JSONDecoder().decode(SessionStart.Reply.self, from: parsed.body)
    }

    private func decodeInput(_ response: Data) throws -> SessionInput.Reply {
        let parsed = try XCTUnwrap(MirrorTransport.parseResponse(response))
        XCTAssertEqual(parsed.status, 200)
        return try JSONDecoder().decode(SessionInput.Reply.self, from: parsed.body)
    }

    private func writeSession(pid: Int32, pipe: String, to dir: URL) throws {
        let sessions = dir.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let record: [String: Any] = [
            "pid": pid,
            "sessionId": "99999999-8888-7777-6666-555555555555",
            "cwd": "D:\\w\\synthetic",
            "startedAt": 1_788_494_441_754,
            "peerProtocol": 1,
            "kind": "interactive",
            "messagingSocketPath": pipe,
            "name": "fixture-owned",
            "status": "idle",
            "statusUpdatedAt": 1_788_495_080_643,
        ]
        try JSONSerialization.data(withJSONObject: record)
            .write(to: sessions.appendingPathComponent("\(pid).json"))
    }
}
