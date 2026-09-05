import XCTest
@testable import InfinitusCore

final class TeamInvitesTests: XCTestCase {
    func testNonceIsRandomBase32() {
        let a = TeamInvites.newNonce(), b = TeamInvites.newNonce()
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.count, 26)
        XCTAssertTrue(a.allSatisfy { "abcdefghijklmnopqrstuvwxyz234567".contains($0) })
    }

    func testMatchesOnlyUnexpiredIssuedNonces() {
        var book = TeamInvites()
        book.add(nonce: "n1", expires: 1_000)
        book.add(nonce: "n2", expires: 2_000)
        let keys = TeamIdentity.random().keys
        func req(_ nonce: String?) -> TeamRequest { TeamRequest(keys: keys, name: "x", devices: [], platform: "macos", at: 1, nonce: nonce) }
        XCTAssertTrue(book.matches(req("n1"), now: 999))
        XCTAssertFalse(book.matches(req("n1"), now: 1_001), "expired")
        XCTAssertFalse(book.matches(req("n3"), now: 1), "never issued")
        XCTAssertFalse(book.matches(req(nil), now: 1), "a team code has no nonce")
        book.consume("n2")
        XCTAssertFalse(book.matches(req("n2"), now: 1), "one-time")
        book.add(nonce: "n4", expires: 5)
        book.prune(now: 10)
        XCTAssertEqual(book.nonces, ["n1": 1_000])
    }

    func testRoundTripsThroughTheTeamDir() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("invites-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var book = TeamInvites(); book.add(nonce: "n", expires: 9)
        try book.save(teamDir: dir)
        XCTAssertEqual(TeamInvites.load(teamDir: dir), book)
        XCTAssertEqual(TeamInvites.load(teamDir: dir.appendingPathComponent("missing")), TeamInvites())
    }

    func testCodeCarriesTheNonceAndAutoApprovalIsTheLeadersDecision() throws {
        let leader = TeamIdentity.random()
        let paths = TeamPaths(base: FileManager.default.temporaryDirectory.appendingPathComponent("inv-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: paths.base) }
        let secrets = FileSecrets(dir: paths.secretsDir)
        try secrets.write(TeamClient.identitySecretName, leader.secret)
        // A bare remote is needed for create; reuse the membership tests' helper shape.
        let bare = paths.base.appendingPathComponent("remote.git")
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = ["git", "init", "--bare", "-q", bare.path]
        try p.run(); p.waitUntilExit()
        let client = try TeamClient.create(name: "T", remote: "file://" + bare.path, token: nil, paths: paths, secrets: secrets, now: 100)
        let nonce = TeamInvites.newNonce()
        let text = try client.code(expiresIn: 600, nonce: nonce, now: 100)
        XCTAssertEqual(try TeamCode.decode(text, now: 101).nonce, nonce)
        XCTAssertNil(try TeamCode.decode(try client.code(expiresIn: 600, now: 100), now: 101).nonce)
    }
}
