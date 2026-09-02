#if canImport(Glibc)
import XCTest
import Glibc
@testable import InfinitusCore

/// The Linux phone-companion listener (#9 parity): a real client and a
/// real server on loopback, exercising the exact auth contract
/// `MirrorTransport` defines — no token, wrong token, right token.
final class PosixHTTPServerTests: XCTestCase {
    static let token = "TESTTOKENTESTTOKENTESTTO"
    var token: String { Self.token }

    func startServer() throws -> (server: PosixHTTPServer, port: UInt16) {
        let expected = Self.token
        let server = PosixHTTPServer { request in
            guard MirrorTransport.isAuthorized(request, token: expected) else {
                return MirrorTransport.unauthorizedResponse()
            }
            guard request.method == "GET", request.path == MirrorTransport.snapshotPath else {
                return MirrorTransport.notFoundResponse()
            }
            return MirrorTransport.snapshotResponse(Data(#"{"machineName":"linux-test"}"#.utf8))
        }
        let port = try server.start(port: 0)
        return (server, port)
    }

    /// A minimal blocking client: connect, send a raw HTTP request, read
    /// the whole response. No URLSession — this test is about the socket
    /// plumbing, not the client library.
    func fetch(port: UInt16, path: String, headers: [String: String] = [:]) -> MirrorTransport.HTTPResponse? {
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }
        var head = "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        let bytes = Array(head.utf8)
        bytes.withUnsafeBufferPointer { buf in
            _ = send(fd, buf.baseAddress, buf.count, 0)
        }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = chunk.withUnsafeMutableBytes { raw in read(fd, raw.baseAddress, raw.count) }
            guard n > 0 else { break }
            buffer.append(contentsOf: chunk[0..<n])
            if let response = MirrorTransport.parseResponse(buffer) { return response }
        }
        return MirrorTransport.parseResponse(buffer)
    }

    func testNoTokenIsUnauthorized() throws {
        let (server, port) = try startServer()
        defer { server.stop() }
        let response = fetch(port: port, path: MirrorTransport.snapshotPath)
        XCTAssertEqual(response?.status, 401)
    }

    func testWrongTokenIsUnauthorized() throws {
        let (server, port) = try startServer()
        defer { server.stop() }
        let response = fetch(port: port, path: MirrorTransport.snapshotPath,
                             headers: ["Authorization": "Bearer WRONGWRONGWRONGWRONGWRON"])
        XCTAssertEqual(response?.status, 401)
    }

    func testRightTokenServesTheSnapshot() throws {
        let (server, port) = try startServer()
        defer { server.stop() }
        let response = fetch(port: port, path: MirrorTransport.snapshotPath,
                             headers: ["Authorization": "Bearer \(token)"])
        XCTAssertEqual(response?.status, 200)
        XCTAssertEqual(response?.body, Data(#"{"machineName":"linux-test"}"#.utf8))
    }

    func testUnknownRouteIsNotFound() throws {
        let (server, port) = try startServer()
        defer { server.stop() }
        let response = fetch(port: port, path: "/nope",
                             headers: ["Authorization": "Bearer \(token)"])
        XCTAssertEqual(response?.status, 404)
    }
}
#endif
