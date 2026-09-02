import XCTest
@testable import InfinitusCore

final class MirrorTransportTests: XCTestCase {
    func testRequestTargetNeedsAWholeLine() {
        XCTAssertNil(MirrorTransport.requestTarget(Data("GET /snap".utf8)))
        let target = MirrorTransport.requestTarget(
            Data("GET /snapshot HTTP/1.1\r\nHost: x\r\n\r\n".utf8))
        XCTAssertEqual(target?.method, "GET")
        XCTAssertEqual(target?.path, MirrorTransport.snapshotPath)
    }

    func testSnapshotResponseRoundTrips() {
        let body = Data(#"{"machineName":"Test Mac"}"#.utf8)
        let parsed = MirrorTransport.parseResponse(MirrorTransport.snapshotResponse(body))
        XCTAssertEqual(parsed, MirrorTransport.HTTPResponse(status: 200, body: body))
    }

    /// TCP hands headers and body over in arbitrary chunks: the client
    /// must keep receiving until Content-Length is satisfied.
    func testParseResponseWaitsForTheWholeBody() {
        let body = Data(repeating: 0x41, count: 300)
        let whole = MirrorTransport.snapshotResponse(body)
        XCTAssertNil(MirrorTransport.parseResponse(whole.prefix(20)))
        XCTAssertNil(MirrorTransport.parseResponse(whole.dropLast(1)))
        XCTAssertEqual(MirrorTransport.parseResponse(whole)?.body, body)
        // Trailing bytes from a pipelined peer never leak into the body.
        var extra = whole
        extra.append(Data("junk".utf8))
        XCTAssertEqual(MirrorTransport.parseResponse(extra)?.body, body)
    }

    func testParseErrorResponses() {
        XCTAssertEqual(MirrorTransport.parseResponse(
            MirrorTransport.notFoundResponse())?.status, 404)
        XCTAssertEqual(MirrorTransport.parseResponse(
            MirrorTransport.unavailableResponse())?.status, 503)
    }

    func testParseEndpoint() {
        let host = MirrorTransport.parseEndpoint(" 192.168.1.20:8080 ")
        XCTAssertEqual(host?.host, "192.168.1.20")
        XCTAssertEqual(host?.port, 8080)
        // Bare host falls back to the advertised default port.
        XCTAssertEqual(MirrorTransport.parseEndpoint("mac.local")?.port,
                       MirrorTransport.defaultPort)
        XCTAssertEqual(MirrorTransport.parseEndpoint("[fe80::1]:47824")?.host, "fe80::1")
        XCTAssertEqual(MirrorTransport.parseEndpoint("fe80::1")?.host, "fe80::1")
        XCTAssertNil(MirrorTransport.parseEndpoint("   "))
    }
}
