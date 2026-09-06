import XCTest
@testable import InfinitusCore

final class TeamMirrorTests: XCTestCase {
    func testPathsSitOutsideTheNearbyPrefixAndUnderTheirOwn() {
        for p in [TeamMirror.aggregatesPath, TeamMirror.memberPath, TeamMirror.transcriptPath,
                  TeamMirror.approvePath, TeamMirror.declinePath, TeamMirror.joinPath, TeamMirror.codePath] {
            XCTAssertTrue(p.hasPrefix(TeamMirror.prefix + "/"), p)
            XCTAssertFalse(p.hasPrefix(TeamNearby.routePrefix), "\(p) would be token-exempt from the LAN")
        }
    }

    func testQueriesRoundTripThroughTheRequestParser() {
        let q = TeamMirror.memberQuery(kid: "abc", period: .month)
        let r = MirrorTransport.Request(method: "GET", target: TeamMirror.memberPath + "?" + q, headers: [:], body: Data())
        XCTAssertEqual(r.path, TeamMirror.memberPath)
        XCTAssertEqual(r.query("kid"), "abc")
        XCTAssertEqual(r.query("period"), "month")
        let t = MirrorTransport.Request(method: "GET", target: TeamMirror.transcriptPath + "?" + TeamMirror.transcriptQuery(kid: "k", session: "s 1"), headers: [:], body: Data())
        XCTAssertEqual(t.query("session"), "s 1", "percent-encoded on the way out, decoded on the way in")
    }

    func testRepliesAreCodable() throws {
        let reply = TeamMirror.ActionReply(ok: false, error: "Turn on biometric unlock first", code: nil)
        XCTAssertEqual(try JSONDecoder().decode(TeamMirror.ActionReply.self, from: try JSONEncoder().encode(reply)), reply)
        let m = TeamMirror.MemberReply(kid: "k", name: "Ann", summary: nil, sessions: [], transcripts: ["s1"])
        XCTAssertEqual(try JSONDecoder().decode(TeamMirror.MemberReply.self, from: try JSONEncoder().encode(m)), m)
    }
}
