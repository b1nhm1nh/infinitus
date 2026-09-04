import XCTest
@testable import InfinitusCore

final class TeamClientTests: XCTestCase {
    var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("teamclient-\(UUID().uuidString)")
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

    /// One "machine": its own paths and secrets.
    func machine(_ name: String) -> (TeamPaths, FileSecrets) {
        let paths = TeamPaths(base: scratch.appendingPathComponent(name))
        return (paths, FileSecrets(dir: paths.secretsDir))
    }

    func testIdentityIsCreatedOnceAndReloaded() throws {
        let (paths, secrets) = machine("a")
        let first = try TeamClient.identity(paths: paths, secrets: secrets)
        let again = try TeamClient.identity(paths: paths, secrets: secrets)
        XCTAssertEqual(first.keys, again.keys)
        XCTAssertEqual(secrets.read("identity")?.count, 32)
    }

    func testCreateRequestApprovePublishRead() throws {
        let remote = try makeRemote()
        let (lp, ls) = machine("leader")
        let (mp, ms) = machine("member")
        let (sp, ss) = machine("stranger")

        let leader = try TeamClient.create(name: "Papaya", remote: remote, token: nil, paths: lp, secrets: ls, now: 1_000)
        XCTAssertTrue(leader.isLeader)
        XCTAssertEqual(try leader.status().role, "leader")
        XCTAssertEqual(lp.teamIDs(), [leader.config.id])

        let code = try leader.code(expiresIn: 60, now: 1_000)
        let member = try TeamClient.request(code: code, name: "Bo", devices: ["Mac"], platform: "macos",
                                            paths: mp, secrets: ms, now: 1_010)
        XCTAssertFalse(member.isMember)
        XCTAssertEqual(try member.status().role, "pending")
        XCTAssertEqual(member.config.leaderKid, leader.identity.kid)
        XCTAssertThrowsError(try member.code()) { XCTAssertEqual($0 as? TeamClient.ClientError, .notALeader) }
        XCTAssertThrowsError(try member.publish(kind: "now", path: "now.json", plaintext: Data(), audience: .leaders)) {
            XCTAssertEqual($0 as? TeamClient.ClientError, .notInTeam)
        }
        // Expired code.
        XCTAssertThrowsError(try TeamClient.request(code: code, name: "Late", devices: [], platform: "linux",
                                                    paths: sp, secrets: ss, now: 2_000))

        _ = try leader.fetch()
        let pending = try leader.requests()
        XCTAssertEqual(pending.map(\.doc.name), ["Bo"])
        XCTAssertThrowsError(try leader.approve(kid: "nobody")) { XCTAssertEqual($0 as? TeamClient.ClientError, .unknownRequest) }
        try leader.approve(kid: member.identity.kid, now: 1_020)
        XCTAssertEqual(try leader.requests(), [])
        XCTAssertEqual(leader.roster?.doc.rev, 2)
        XCTAssertEqual(leader.roster?.doc.members.map(\.name), ["Bo"])

        let roster = try member.fetch()
        XCTAssertTrue(member.isMember)
        XCTAssertEqual(roster.rev, 2)
        XCTAssertEqual(try member.status().role, "member")

        // Member publishes to leaders; the leader reads it; a stranger with the code can't.
        let path = try member.publish(kind: "now", path: "now.json", plaintext: Data("{\"busy\":1}".utf8),
                                      audience: .leaders, now: 1_030)
        XCTAssertEqual(path, "m/\(member.identity.kid)/now.json")
        _ = try leader.fetch()
        XCTAssertEqual(try leader.readable().map(\.path), [path])
        let (header, plain) = try leader.read(path)
        XCTAssertEqual(header.kind, "now")
        XCTAssertEqual(header.from, member.identity.kid)
        XCTAssertEqual(plain, Data("{\"busy\":1}".utf8))
        XCTAssertEqual(try member.read(path).1, plain)   // own file

        let stranger = try TeamClient.request(code: try leader.code(expiresIn: 60, now: 1_040), name: "Eve",
                                              devices: [], platform: "linux", paths: sp, secrets: ss, now: 1_041)
        XCTAssertEqual(try stranger.readable(), [])
        XCTAssertThrowsError(try stranger.read(path))

        // Leader publishes to the team; the member reads it after a fetch.
        let team = try leader.publish(kind: "aggregates", path: "aggregates/week.json", plaintext: Data("w".utf8),
                                      audience: .team, now: 1_050)
        _ = try member.fetch()
        XCTAssertEqual(try member.read(team).1, Data("w".utf8))

        // Reopen from disk keeps identity, roster and role.
        let reopened = try TeamClient.open(id: member.config.id, paths: mp, secrets: ms)
        XCTAssertEqual(reopened.identity.keys, member.identity.keys)
        XCTAssertEqual(reopened.roster?.doc.rev, 2)
        XCTAssertTrue(reopened.isMember)

        // A tampered roster on the remote is refused and the last good one kept.
        let raw = TeamGit(dir: sp.storeDir(leader.config.id), remote: remote, token: nil, author: "eve")
        try raw.open()
        var bogus = leader.roster!.doc; bogus.rev = 3; bogus.leaders.append(TeamRoster.Member(keys: stranger.identity.keys, name: "Eve", since: 1))
        try raw.put("roster/team.json", try CanonicalJSON.encode(try Signed.make(bogus, by: stranger.identity)))
        XCTAssertThrowsError(try member.fetch())
        XCTAssertEqual(member.roster?.doc.rev, 2)
    }
}
