import XCTest
@testable import InfinitusCore

/// The backend-free remote access rules (#9): the pairing token, what a
/// QR encodes, which of this machine's addresses is worth offering, and
/// how cloudflared announces a quick tunnel.
final class MirrorPairingTests: XCTestCase {
    func testGeneratedTokenIsBase32AndUnrepeated() {
        let token = MirrorPairing.generateToken()
        XCTAssertEqual(token.count, MirrorPairing.tokenLength)
        XCTAssertTrue(token.allSatisfy(Set(MirrorPairing.alphabet).contains))
        // 32^24 of entropy: a collision in ten draws would mean the RNG
        // isn't one.
        XCTAssertEqual(Set((0..<10).map { _ in MirrorPairing.generateToken() }).count, 10)
    }

    func testNormalizeSurvivesHumanTyping() {
        XCTAssertEqual(MirrorPairing.normalize(" abcd-2345\n"), "ABCD2345")
        // 0/1/8/9 aren't in the alphabet at all, so they can't be a token.
        XCTAssertEqual(MirrorPairing.normalize("A0B1C8"), "ABC")
        XCTAssertEqual(MirrorPairing.normalize(""), "")
    }

    func testMatchesComparesWholeToken() {
        XCTAssertTrue(MirrorPairing.matches("ABCDEF", "ABCDEF"))
        XCTAssertFalse(MirrorPairing.matches("ABCDEF", "ABCDEG"))
        XCTAssertFalse(MirrorPairing.matches("ABCDE", "ABCDEF"))
        XCTAssertFalse(MirrorPairing.matches("", "ABCDEF"))
    }

    func testMaskShowsTheEnds() {
        XCTAssertEqual(MirrorPairing.mask("ABCD234567WXYZ"), "ABCD••••••WXYZ")
        XCTAssertEqual(MirrorPairing.mask("ABCD"), "••••")
    }

    func testPairURLRoundTrips() {
        let url = MirrorPairing.pairURL(endpoint: "http://192.168.1.20:47824",
                                        token: "abcd2345")
        XCTAssertTrue(url.hasPrefix("infinitus://pair?url="))
        // The endpoint's own colons and slashes are escaped, so they
        // can't be read as another query parameter.
        XCTAssertFalse(url.contains("http://192.168.1.20:47824"))
        let pairing = MirrorPairing.parsePairURL(url)
        XCTAssertEqual(pairing?.endpoint, "http://192.168.1.20:47824")
        XCTAssertEqual(pairing?.token, "ABCD2345")
    }

    func testParsePairURLRejectsAnythingElse() {
        XCTAssertNil(MirrorPairing.parsePairURL("https://evil.example/pair?token=AB"))
        XCTAssertNil(MirrorPairing.parsePairURL("infinitus://other?token=AB"))
        // No token, no pairing — the endpoint alone is useless now.
        XCTAssertNil(MirrorPairing.parsePairURL("infinitus://pair?url=http://x"))
        // A tunnel QR carries an https endpoint and no port.
        let tunnel = MirrorPairing.parsePairURL(
            MirrorPairing.pairURL(endpoint: "https://calm-fox.trycloudflare.com",
                                  token: "ZZZZ7777"))
        XCTAssertEqual(tunnel?.endpoint, "https://calm-fox.trycloudflare.com")
    }

    func testTailnetAddressIsTheCGNATOne() {
        let addresses = ["192.168.1.20", "100.101.102.103", "169.254.9.9"]
        XCTAssertEqual(MirrorPairing.tailnetAddress(in: addresses), "100.101.102.103")
        // 100.128.x is public space, not Tailscale's 100.64.0.0/10.
        XCTAssertNil(MirrorPairing.tailnetAddress(in: ["100.128.0.1", "100.63.0.1"]))
        XCTAssertNil(MirrorPairing.tailnetAddress(in: []))
    }

    func testLanAddressSkipsLoopbackLinkLocalAndTailnet() {
        XCTAssertEqual(MirrorPairing.lanAddress(
            in: ["127.0.0.1", "169.254.1.1", "100.90.1.2", "192.168.2.36"]),
                       "192.168.2.36")
        XCTAssertNil(MirrorPairing.lanAddress(in: ["100.90.1.2", "fe80::1"]))
    }

    func testQuickTunnelURLOutOfCloudflaredNoise() {
        let line = "2026-09-02T10:00:00Z INF |  https://calm-fox-1234.trycloudflare.com  |"
        XCTAssertEqual(MirrorPairing.quickTunnelURL(in: line),
                       "https://calm-fox-1234.trycloudflare.com")
        // cloudflared logs plenty of other https URLs (docs, metrics).
        XCTAssertNil(MirrorPairing.quickTunnelURL(
            in: "INF see https://developers.cloudflare.com/argo-tunnel"))
        XCTAssertNil(MirrorPairing.quickTunnelURL(in: "INF starting tunnel"))
    }
}
