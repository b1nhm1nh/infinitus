import XCTest
@testable import InfinitusCore

final class MirrorRendezvousTests: XCTestCase {
    func testKeyIsSHA256HexOfTheNormalizedToken() {
        // Tokens normalize to the upper-case alphabet: echo -n ABC | shasum -a 256
        XCTAssertEqual(MirrorRendezvous.key(token: "abc"),
                       "b5d4045c3f466fa91fe2cc6abe79232a1a57cdf104f7a26e716e0a1e2789df78")
        XCTAssertEqual(MirrorRendezvous.key(token: " abc\n"), MirrorRendezvous.key(token: "abc"))
        XCTAssertNil(MirrorRendezvous.key(token: "  "))
    }

    func testURLUsesTheDefaultBase() {
        XCTAssertEqual(MirrorRendezvous.url(token: "abc")?.absoluteString,
                       "https://infinitus.run/rendezvous/b5d4045c3f466fa91fe2cc6abe79232a1a57cdf104f7a26e716e0a1e2789df78")
    }

    func testOnlyQuickTunnelURLsAreEphemeral() {
        XCTAssertTrue(MirrorRendezvous.isEphemeral("https://abc-def.trycloudflare.com"))
        XCTAssertFalse(MirrorRendezvous.isEphemeral("https://tunnel.infinitus.run"))
        XCTAssertFalse(MirrorRendezvous.isEphemeral("192.168.2.36:47824"))
    }

    func testLookupParsesOnlyQuickTunnelURLs() {
        XCTAssertEqual(MirrorRendezvous.parseLookup(Data(#"{"url":"https://x.trycloudflare.com"}"#.utf8)),
                       "https://x.trycloudflare.com")
        XCTAssertNil(MirrorRendezvous.parseLookup(Data(#"{"url":"https://evil.example"}"#.utf8)))
        XCTAssertNil(MirrorRendezvous.parseLookup(Data("nope".utf8)))
    }

    func testPublishBody() {
        XCTAssertEqual(String(decoding: MirrorRendezvous.publishBody(url: "https://x.trycloudflare.com"), as: UTF8.self),
                       #"{"url":"https:\/\/x.trycloudflare.com"}"#)
    }
}
