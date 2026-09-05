import XCTest
@testable import InfinitusCore

final class TeamPublisherTests: XCTestCase {
    var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("teampub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    func makeRemote() throws -> String {
        let bare = scratch.appendingPathComponent("remote.git")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "init", "--bare", "-q", bare.path]
        try p.run(); p.waitUntilExit()
        return "file://" + bare.path
    }

    func machine(_ name: String) -> (TeamPaths, FileSecrets) {
        let paths = TeamPaths(base: scratch.appendingPathComponent(name))
        return (paths, FileSecrets(dir: paths.secretsDir))
    }

    /// Same fixture as TeamCollectTests.TeamFixture (repeated: each test
    /// file stands alone). s1 in /r/app (10 tokens) + agent-a1 (5), s2 in
    /// /r/secret (10); the user prompt carries an `sk-ant-…` key.
    func writeProjects(_ root: URL) throws -> URL {
        let user = #"{"type":"user","cwd":"%CWD%","timestamp":"2026-09-04T12:00:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"use sk-ant-api03-abcdefghijklmnopqrstuvwxyz please"}}"#
        let assistant = #"{"type":"assistant","timestamp":"2026-09-04T12:00:05.000Z","message":{"id":"%ID%","model":"claude-opus-5","usage":{"input_tokens":%IN%,"output_tokens":1},"content":[{"type":"text","text":"sure"}]}}"#
        func transcript(_ cwd: String, _ id: String, _ input: Int) -> String {
            user.replacingOccurrences(of: "%CWD%", with: cwd) + "\n"
                + assistant.replacingOccurrences(of: "%ID%", with: id).replacingOccurrences(of: "%IN%", with: String(input)) + "\n"
        }
        let projects = root.appendingPathComponent("projects")
        let app = projects.appendingPathComponent("-r-app"), secret = projects.appendingPathComponent("-r-secret")
        let sub = app.appendingPathComponent("s1/subagents")
        for dir in [app, secret, sub] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try transcript("/r/app", "a1", 10).write(to: app.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)
        try transcript("/r/app", "a2", 5).write(to: sub.appendingPathComponent("agent-a1.jsonl"), atomically: true, encoding: .utf8)
        try transcript("/r/secret", "a3", 10).write(to: secret.appendingPathComponent("s2.jsonl"), atomically: true, encoding: .utf8)
        return projects
    }

    struct Team {
        let leader: TeamClient, alice: TeamClient, bob: TeamClient
        let alicePaths: TeamPaths
    }

    /// Leader + two approved members; alice is the publisher under test.
    func team() throws -> Team {
        let remote = try makeRemote()
        let (lp, ls) = machine("leader"), (ap, asec) = machine("alice"), (bp, bs) = machine("bob")
        let leader = try TeamClient.create(name: "Papaya", remote: remote, token: nil, paths: lp, secrets: ls, now: 1_000)
        let code = try leader.code(expiresIn: 600, now: 1_000)
        let alice = try TeamClient.request(code: code, name: "Alice", devices: [], platform: "linux", paths: ap, secrets: asec, now: 1_010)
        let bob = try TeamClient.request(code: code, name: "Bob", devices: [], platform: "linux", paths: bp, secrets: bs, now: 1_011)
        _ = try leader.fetch()
        try leader.approve(kid: alice.identity.kid, now: 1_020)
        try leader.approve(kid: bob.identity.kid, now: 1_021)
        _ = try alice.fetch(); _ = try bob.fetch()
        return Team(leader: leader, alice: alice, bob: bob, alicePaths: ap)
    }

    func sources(_ projects: URL) -> TeamPublisher.Sources {
        var s = TeamPublisher.Sources(projectsDir: projects, home: "/Users/alice")
        s.historyDays = 10_000   // the fixture's dates stay in the window whenever this runs
        s.liveSessions = [ClaudeSessionRecord(pid: 1, sessionId: "s1", cwd: "/r/app", status: "busy"),
                          ClaudeSessionRecord(pid: 2, sessionId: "s2", cwd: "/r/secret", status: "idle")]
        s.crashes = [CrashReport(platform: "mac", device: "Mac", appVersion: "1", osVersion: "26", at: Date(), kind: "crash", reason: "SIGSEGV")]
        s.fleets = [TeamDocs.Fleet(engine: "opaque", account: "acct-1", windows: [TeamDocs.Window(label: "5h", pct: 40)])]
        return s
    }

    func header(_ client: TeamClient, _ path: String) throws -> Envelope.Header {
        try XCTUnwrap(try client.readableHeaders().first { $0.entry.path == path }?.header)
    }

    func testPublishWrapsEachKindToItsAudienceHonoursExclusionsAndRedacts() throws {
        let t = try team()
        let projects = try writeProjects(scratch)
        let teamDir = t.alicePaths.teamDir(t.alice.config.id)
        var shares = TeamShares()
        shares.byKind["stats"] = .team
        shares.byKind["sessions"] = .members([t.bob.identity.kid])
        try shares.save(teamDir: teamDir)
        var ex = TeamExclusions(); ex.set("/r/secret", excluded: true); try ex.save(paths: t.alicePaths)

        let publisher = TeamPublisher(client: t.alice, paths: t.alicePaths)
        let report = try publisher.publish(sources: sources(projects))
        let me = "m/\(t.alice.identity.kid)/"
        XCTAssertEqual(Set(report.published), [
            me + "days/2026-09-04.json", me + "sessions/index.json", me + "now.json", me + "crashes.json",
            me + "transcripts/s1/1.jsonl", me + "transcripts/s1/subagents/agent-a1/1.jsonl",
        ])
        XCTAssertEqual(report.transcriptChunks, 2)

        _ = try t.leader.fetch(); _ = try t.bob.fetch()
        // stats → team: leader and bob read it; sessions → bob only; the rest → leaders.
        let dayHeader = try header(t.leader, me + "days/2026-09-04.json")
        XCTAssertEqual(Set(dayHeader.to.map(\.kid)), [t.leader.identity.kid, t.alice.identity.kid, t.bob.identity.kid])
        XCTAssertEqual(Set(try t.bob.readable().map(\.path)), [me + "days/2026-09-04.json", me + "sessions/index.json"])
        XCTAssertFalse(try t.leader.readable().map(\.path).contains(me + "sessions/index.json"))
        let chunkHeader = try header(t.leader, me + "transcripts/s1/1.jsonl")
        XCTAssertEqual(Set(chunkHeader.to.map(\.kid)), [t.leader.identity.kid, t.alice.identity.kid])

        // Excluded project: no day contribution, no session row, no transcript, no live session.
        let day = try CanonicalJSON.decode(TeamDocs.DayDoc.self, from: try t.leader.read(me + "days/2026-09-04.json").1)
        XCTAssertEqual(day.day, "2026-09-04")
        XCTAssertEqual(day.stats.inputTokens, 15)
        let index = try CanonicalJSON.decode(TeamDocs.SessionsIndex.self, from: try t.bob.read(me + "sessions/index.json").1)
        XCTAssertEqual(index.sessions.map(\.id), ["s1"])
        XCTAssertEqual(index.fleets.first?.account, "acct-1")
        let now = try CanonicalJSON.decode(TeamDocs.Now.self, from: try t.leader.read(me + "now.json").1)
        XCTAssertEqual(now.sessions.map(\.id), ["s1"])
        XCTAssertEqual(now.sessions.first?.project, "app")
        XCTAssertEqual(now.crashesToday, 1)
        XCTAssertEqual(now.sharesTo["stats"], .team)
        let crashes = try CanonicalJSON.decode(TeamDocs.Crashes.self, from: try t.leader.read(me + "crashes.json").1)
        XCTAssertEqual(crashes.crashes, ["Mac · crash · SIGSEGV"])
        XCTAssertFalse(try t.leader.readable().map(\.path).contains { $0.contains("/s2/") })

        // Redacted before sealing; the local copy is the redacted text too.
        let chunk = String(decoding: try t.leader.read(me + "transcripts/s1/1.jsonl").1, as: UTF8.self)
        XCTAssertFalse(chunk.contains("sk-ant"))
        XCTAssertTrue(chunk.contains("[redacted-key]"))
        let copy = try String(contentsOf: publisher.copiesDir.appendingPathComponent("transcripts/s1/1.jsonl"), encoding: .utf8)
        XCTAssertEqual(copy, chunk)

        // Nothing changed: only the every-push files go out again, no chunks.
        let second = try publisher.publish(sources: sources(projects))
        XCTAssertEqual(Set(second.published), [me + "sessions/index.json", me + "now.json"])
        XCTAssertEqual(second.transcriptChunks, 0)
        XCTAssertEqual(second.skipped, 2)   // the day and the crash list

        // New lines → the next chunk, seq 2, and the day changes with them.
        let s1 = projects.appendingPathComponent("-r-app/s1.jsonl")
        let handle = try FileHandle(forWritingTo: s1)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"type":"assistant","timestamp":"2026-09-04T12:00:09.000Z","message":{"id":"a9","model":"claude-opus-5","usage":{"input_tokens":7,"output_tokens":1},"content":[{"type":"text","text":"more"}]}}"#.utf8 + [UInt8(ascii: "\n")]))
        try handle.close()
        let third = try publisher.publish(sources: sources(projects))
        XCTAssertTrue(third.published.contains(me + "transcripts/s1/2.jsonl"))
        XCTAssertTrue(third.published.contains(me + "days/2026-09-04.json"))
        XCTAssertEqual(third.transcriptChunks, 1)
        XCTAssertEqual(TeamPublishState.load(teamDir: teamDir).transcripts["s1"]?.seq, 2)

        // quit deletes now.json.
        try publisher.quit()
        _ = try t.leader.fetch()
        XCTAssertFalse(try t.leader.readable().map(\.path).contains(me + "now.json"))
    }

    func testReshareRewrapsHistoryToTheCurrentAudienceAfterPromotion() throws {
        let t = try team()
        let projects = try writeProjects(scratch)
        var ex = TeamExclusions(); ex.set("/r/secret", excluded: true); try ex.save(paths: t.alicePaths)
        let publisher = TeamPublisher(client: t.alice, paths: t.alicePaths)
        _ = try publisher.publish(sources: sources(projects))
        let me = "m/\(t.alice.identity.kid)/"
        _ = try t.leader.fetch()
        XCTAssertFalse(try header(t.leader, me + "transcripts/s1/1.jsonl").to.contains { $0.kid == t.bob.identity.kid })

        try t.leader.promote(kid: t.bob.identity.kid, now: 2_000)
        _ = try t.alice.fetch()
        let report = try publisher.reshare(days: 10_000)
        XCTAssertEqual(Set(report.published), [
            me + "days/2026-09-04.json", me + "sessions/index.json", me + "crashes.json",
            me + "transcripts/s1/1.jsonl", me + "transcripts/s1/subagents/agent-a1/1.jsonl",
        ])   // never now.json: live state is stale by definition and is gone after quit
        _ = try t.bob.fetch()
        XCTAssertTrue(try header(t.bob, me + "transcripts/s1/1.jsonl").to.contains { $0.kid == t.bob.identity.kid })
        XCTAssertFalse(String(decoding: try t.bob.read(me + "transcripts/s1/1.jsonl").1, as: UTF8.self).contains("sk-ant"))
        // A zero-day window re-shares nothing.
        XCTAssertEqual(try publisher.reshare(days: 0, now: Date(timeIntervalSince1970: 4_000_000_000)).published, [])
    }

    func testPendingMemberCannotPublish() throws {
        let remote = try makeRemote()
        let (lp, ls) = machine("leader"), (pp, ps) = machine("pending")
        let leader = try TeamClient.create(name: "P", remote: remote, token: nil, paths: lp, secrets: ls, now: 1_000)
        let pending = try TeamClient.request(code: try leader.code(expiresIn: 600, now: 1_000), name: "X", devices: [],
                                             platform: "linux", paths: pp, secrets: ps, now: 1_001)
        let projects = try writeProjects(scratch)
        XCTAssertThrowsError(try TeamPublisher(client: pending, paths: pp).publish(sources: sources(projects))) {
            XCTAssertEqual($0 as? TeamClient.ClientError, .notInTeam)
        }
    }
}
