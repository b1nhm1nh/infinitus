import XCTest
import InfinitusCore
@testable import InfinitusWin

/// Grantor pass decisions without a live remote. Core already covers
/// envelope crypto; this file pins the Windows wiring: cadence vs TTL,
/// plan/apply split, execute through `DeliveryLane`, and the serial queue
/// that stops a grantor and an HTTP input interleaving frames.
final class TeamSupervisorTests: XCTestCase {
    let grantor = TeamIdentity.random()
    let driver = TeamIdentity.random()

    func testCadenceIsUnderStoreTTL() {
        XCTAssertEqual(TeamSupervisor.tickSeconds, 300)
        XCTAssertLessThan(TeamSupervisor.tickSeconds, TimeInterval(TeamControl.storeTTL),
                          "a tick at or above storeTTL silently drops commands as expired")
    }

    func testPlanSkipsWithoutGit() {
        let supervisor = TeamSupervisor(claudeDir: URL(fileURLWithPath: NSTemporaryDirectory()),
                                        owned: OwnedSessionsBox(), log: { _ in })
        let plan = supervisor.plan(teamIDs: ["team-1"], gitFound: false)
        XCTAssertEqual(plan.skipped, "git not found — install Git for Windows")
        XCTAssertNil(plan.teamID)
    }

    func testPlanSkipsWithoutATeam() {
        let supervisor = TeamSupervisor(claudeDir: URL(fileURLWithPath: NSTemporaryDirectory()),
                                        owned: OwnedSessionsBox(), log: { _ in })
        let plan = supervisor.plan(teamIDs: [], gitFound: true)
        XCTAssertEqual(plan.skipped, "not in a team")
        XCTAssertNil(plan.teamID)
    }

    func testPlanPicksTheFirstTeam() {
        let supervisor = TeamSupervisor(claudeDir: URL(fileURLWithPath: NSTemporaryDirectory()),
                                        owned: OwnedSessionsBox(), log: { _ in })
        let plan = supervisor.plan(teamIDs: ["zeta", "alpha"], gitFound: true)
        XCTAssertEqual(plan.teamID, "alpha", "teamIDs() is sorted; first is the Mac's choice too")
        XCTAssertNil(plan.skipped)
    }

    func testGrantedMessageReachesDeliveryLane() throws {
        try DaemonHarness.scratch { dir in
            try self.writeSession(pid: SelfProcess.pid, to: dir)
            let hit = Flag()
            let supervisor = TeamSupervisor(
                claudeDir: dir, owned: OwnedSessionsBox(),
                deliverOverride: { request, record in
                    XCTAssertEqual(request.kind, .message)
                    XCTAssertTrue(request.text.contains("hello"), request.text)
                    XCTAssertEqual(record.pid, SelfProcess.pid)
                    hit.value = true
                    return SessionInput.Reply(outcome: "delivered", channel: "stdin")
                }, log: { _ in })
            var ep = self.endpoint(supervisor, grants: self.sendGrant())
            let (ack, audit, _) = TeamControl.handle(try self.sealed(self.command()), endpoint: &ep)
            XCTAssertTrue(hit.value, "grantor execute must call DeliveryLane")
            XCTAssertEqual(ack.outcome, "delivered")
            XCTAssertEqual(audit.outcome, "delivered")
            XCTAssertEqual(audit.action, TeamGrants.send)
            XCTAssertFalse(ep.seen.admit("c-0123456789", until: 2_000, now: 1_011), "id is spent")
        }
    }

    func testNoGrantUsesCoresOutcome() throws {
        try DaemonHarness.scratch { dir in
            let supervisor = TeamSupervisor(claudeDir: dir, owned: OwnedSessionsBox(), log: { _ in })
            var ep = self.endpoint(supervisor, grants: TeamGrants())
            let (ack, audit, _) = TeamControl.handle(try self.sealed(self.command()), endpoint: &ep)
            XCTAssertEqual(ack.outcome, TeamControl.Outcome.noGrant)
            XCTAssertEqual(audit.outcome, TeamControl.Outcome.noGrant)
            XCTAssertTrue(ep.seen.admit("c-0123456789", until: 2_000, now: 1_011),
                          "a refused command does not spend its id")
        }
    }

    func testReplayedIdIsNotReExecuted() throws {
        try DaemonHarness.scratch { dir in
            try self.writeSession(pid: SelfProcess.pid, to: dir)
            let hits = Counter()
            let supervisor = TeamSupervisor(
                claudeDir: dir, owned: OwnedSessionsBox(),
                deliverOverride: { _, _ in
                    hits.value += 1
                    return SessionInput.Reply(outcome: "delivered", channel: "stdin")
                }, log: { _ in })
            var ep = self.endpoint(supervisor, grants: self.sendGrant())
            XCTAssertEqual(TeamControl.handle(try self.sealed(self.command()), endpoint: &ep).ack.outcome, "delivered")
            XCTAssertEqual(TeamControl.handle(try self.sealed(self.command()), endpoint: &ep).ack.outcome,
                           TeamControl.Outcome.replayed)
            XCTAssertEqual(hits.value, 1)
        }
    }

    func testRateLimitRefusesTheSixth() throws {
        try DaemonHarness.scratch { dir in
            try self.writeSession(pid: SelfProcess.pid, to: dir)
            let supervisor = TeamSupervisor(
                claudeDir: dir, owned: OwnedSessionsBox(),
                deliverOverride: { _, _ in SessionInput.Reply(outcome: "delivered", channel: "stdin") },
                log: { _ in })
            var ep = self.endpoint(supervisor, grants: self.sendGrant())
            for i in 0..<TeamControl.RateLimit.commands {
                XCTAssertEqual(
                    TeamControl.handle(try self.sealed(self.command(id: "c-r00000000\(i)")), endpoint: &ep).ack.outcome,
                    "delivered")
            }
            XCTAssertEqual(
                TeamControl.handle(try self.sealed(self.command(id: "c-r000000009")), endpoint: &ep).ack.outcome,
                TeamControl.Outcome.rateLimited)
        }
    }

    func testExpiredPastStoreTTLIsSkipped() throws {
        try DaemonHarness.scratch { dir in
            let supervisor = TeamSupervisor(claudeDir: dir, owned: OwnedSessionsBox(), log: { _ in })
            // now = 1_010; command.at + ttl = 400 — well past storeTTL, never mind the default TTL.
            var ep = self.endpoint(supervisor, grants: self.sendGrant())
            let (ack, _, _) = TeamControl.handle(
                try self.sealed(self.command(at: 1, ttl: TeamControl.storeTTL)), endpoint: &ep)
            XCTAssertEqual(ack.outcome, TeamControl.Outcome.expired)
        }
    }

    func testGrantedKeyOnUnownedSessionIsNoSurface() throws {
        try DaemonHarness.scratch { dir in
            try self.writeSession(pid: SelfProcess.pid, to: dir)
            let supervisor = TeamSupervisor(
                claudeDir: dir, owned: OwnedSessionsBox(),
                deliverOverride: { _, _ in nil }, log: { _ in })
            var grants = TeamGrants()
            grants.add(audience: .members([driver.kid]), sessions: .some(["s1"]),
                       capabilities: [TeamGrants.key], now: 900)
            var ep = self.endpoint(supervisor, grants: grants)
            let (ack, _, _) = TeamControl.handle(
                try self.sealed(self.command(action: TeamGrants.key, text: "esc")), endpoint: &ep)
            XCTAssertEqual(ack.outcome, TeamControl.Outcome.noSurface)
        }
    }

    func testHTTPAndGrantorDoNotInterleave() throws {
        try DaemonHarness.scratch { dir in
            try self.writeSession(pid: SelfProcess.pid, to: dir)
            let flight = Flight()
            let override: @Sendable (SessionInput.Request, ClaudeSessionRecord) -> SessionInput.Reply? = { _, _ in
                flight.enter()
                Thread.sleep(forTimeInterval: 0.05)
                flight.leave()
                return SessionInput.Reply(outcome: "delivered", channel: "stdin")
            }
            let supervisor = TeamSupervisor(
                claudeDir: dir, owned: OwnedSessionsBox(), deliverOverride: override, log: { _ in })
            let handler = Routes.handler(
                claudeDir: dir, snapshot: SnapshotCache(claudeDir: dir),
                token: "TESTTOKENTESTTOKENTESTTO", owned: OwnedSessionsBox(),
                deliverOverride: override)
            let body = try JSONEncoder().encode(SessionInput.Request(kind: .message, text: "http"))
            let request = MirrorTransport.Request(
                method: "POST", target: "/sessions/\(SelfProcess.pid)/input",
                headers: ["authorization": "Bearer TESTTOKENTESTTOKENTESTTO",
                          "content-length": "\(body.count)"],
                body: body)

            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                _ = handler(request)
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                var ep = self.endpoint(supervisor, grants: self.sendGrant())
                _ = TeamControl.handle(try! self.sealed(self.command()), endpoint: &ep)
                group.leave()
            }
            XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
            XCTAssertEqual(flight.maxInFlight, 1,
                           "HTTP input and grantor execute must share DeliveryLane.queue")
        }
    }

    func testLastPassRoundTrips() throws {
        try DaemonHarness.scratch { dir in
            let pass = TeamSupervisor.LastPass(at: 1_700, answered: 2,
                                               lastOutcome: "delivered", lastRefusal: "noGrant", error: nil)
            try pass.save(teamDir: dir)
            XCTAssertEqual(TeamSupervisor.LastPass.load(teamDir: dir), pass)
        }
    }

    func testRoutesInputUsesTheSharedLane() throws {
        try DaemonHarness.scratch { dir in
            try self.writeSession(pid: SelfProcess.pid, to: dir)
            let hit = Flag()
            let handler = Routes.handler(
                claudeDir: dir, snapshot: SnapshotCache(claudeDir: dir),
                token: "TESTTOKENTESTTOKENTESTTO", owned: OwnedSessionsBox(),
                deliverOverride: { _, _ in
                    hit.value = true
                    return SessionInput.Reply(outcome: "delivered", channel: "stdin")
                })
            let body = try JSONEncoder().encode(SessionInput.Request(kind: .message, text: "hi"))
            let response = handler(MirrorTransport.Request(
                method: "POST", target: "/sessions/\(SelfProcess.pid)/input",
                headers: ["authorization": "Bearer TESTTOKENTESTTOKENTESTTO",
                          "content-length": "\(body.count)"],
                body: body))
            let parsed = try XCTUnwrap(MirrorTransport.parseResponse(response))
            XCTAssertEqual(parsed.status, 200)
            let reply = try JSONDecoder().decode(SessionInput.Reply.self, from: parsed.body)
            XCTAssertEqual(reply.outcome, "delivered")
            XCTAssertTrue(hit.value)
        }
    }

    // MARK: plumbing

    private final class Flag: @unchecked Sendable { var value = false }
    private final class Counter: @unchecked Sendable { var value = 0 }
    private final class Flight: @unchecked Sendable {
        private let lock = NSLock()
        private var inFlight = 0
        private(set) var maxInFlight = 0
        func enter() {
            lock.lock(); inFlight += 1; maxInFlight = max(maxInFlight, inFlight); lock.unlock()
        }
        func leave() {
            lock.lock(); inFlight -= 1; lock.unlock()
        }
    }

    private func roster() -> TeamRoster {
        TeamRoster(id: "team-1", name: "P", createdAt: 1,
                   leaders: [TeamRoster.Member(keys: grantor.keys, name: "G", since: 1, founder: true)],
                   members: [TeamRoster.Member(keys: driver.keys, name: "D", since: 2)], rev: 1)
    }

    private func sendGrant() -> TeamGrants {
        var g = TeamGrants()
        g.add(audience: .members([driver.kid]), sessions: .some(["s1"]),
              capabilities: [TeamGrants.send], now: 900)
        return g
    }

    private func command(id: String = "c-0123456789", action: String = TeamGrants.send,
                         text: String? = "hello", at: Int = 1_000, ttl: Int = 120) -> TeamControl.Command {
        TeamControl.Command(id: id, to: grantor.kid, session: "s1", action: action, text: text, at: at, ttl: ttl)
    }

    private func sealed(_ cmd: TeamControl.Command) throws -> Data {
        try TeamControl.sealCommand(cmd, from: driver, to: grantor.keys, at: cmd.at)
    }

    private func endpoint(_ supervisor: TeamSupervisor, grants: TeamGrants,
                          now: Int = 1_010) -> TeamControl.Endpoint {
        let roster = roster()
        return supervisor.makeEndpoint(
            identity: grantor,
            roster: { roster },
            grants: { grants },
            liveSessions: { ["s1": SelfProcess.pid] },
            seen: TeamControl.SeenIDs(),
            limit: TeamControl.RateLimit(),
            now: { Date(timeIntervalSince1970: TimeInterval(now)) })
    }

    private func writeSession(pid: Int32, to dir: URL) throws {
        let sessions = dir.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let record: [String: Any] = [
            "pid": pid,
            "sessionId": "s1",
            "cwd": "D:\\w\\synthetic",
            "startedAt": 1_788_494_441_754,
            "peerProtocol": 1,
            "kind": "interactive",
            "messagingSocketPath": "\\\\.\\pipe\\LOCAL\\cc-msg-team-grantor",
            "name": "fixture-team",
            "status": "idle",
            "statusUpdatedAt": 1_788_495_080_643,
        ]
        try JSONSerialization.data(withJSONObject: record)
            .write(to: sessions.appendingPathComponent("\(pid).json"))
    }
}
