import Foundation

// MARK: - LAN mirror transport (#9)
//
// The phone reads the fleet snapshot off the Mac over the local network:
// one Bonjour-advertised TCP listener speaking the smallest possible
// HTTP/1.1 — `GET /snapshot` → the exact bytes MirrorExporter wrote.
// Network.framework is Apple-only, so only the wire format lives here
// (InfinitusCore also compiles for the Linux tray); the listener is in
// Sources/Infinitus/MirrorServer.swift and the client in ios/.

public enum MirrorTransport {
    /// Bonjour service type both sides agree on.
    public static let bonjourType = "_infinitus._tcp"
    /// The one route the server answers.
    public static let snapshotPath = "/snapshot"
    /// Preferred listening port — fixed so the phone's manual
    /// `host:port` override has something to guess when mDNS is blocked.
    /// The server falls back to a kernel-assigned port if it's taken.
    public static let defaultPort: UInt16 = 47824

    // MARK: - Server side

    /// Method + path of an HTTP request, from however many bytes have
    /// arrived so far. `nil` while the request line is still incomplete.
    public static func requestTarget(_ data: Data) -> (method: String, path: String)? {
        guard let end = data.range(of: Data("\r\n".utf8)) else { return nil }
        let line = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self)
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    public static func response(status: Int, reason: String,
                                contentType: String, body: Data) -> Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        return out
    }

    public static func snapshotResponse(_ body: Data) -> Data {
        response(status: 200, reason: "OK", contentType: "application/json", body: body)
    }

    public static func notFoundResponse() -> Data {
        response(status: 404, reason: "Not Found", contentType: "text/plain",
                 body: Data("no such route\n".utf8))
    }

    /// The listener is up but no snapshot has been captured yet.
    public static func unavailableResponse() -> Data {
        response(status: 503, reason: "Service Unavailable", contentType: "text/plain",
                 body: Data("no snapshot yet\n".utf8))
    }

    // MARK: - Client side

    public struct HTTPResponse: Sendable, Equatable {
        public let status: Int
        public let body: Data

        public init(status: Int, body: Data) {
            self.status = status
            self.body = body
        }
    }

    /// Parses an accumulating response buffer. `nil` means "keep
    /// receiving" — TCP hands headers and body over in arbitrary chunks.
    public static func parseResponse(_ buffer: Data) -> HTTPResponse? {
        guard let split = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[buffer.startIndex..<split.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let statusLine = lines.removeFirst().split(separator: " ",
                                                   omittingEmptySubsequences: true)
        guard statusLine.count >= 2, let status = Int(statusLine[1]) else { return nil }
        var length: Int?
        for line in lines {
            let pieces = line.split(separator: ":", maxSplits: 1)
            guard pieces.count == 2,
                  pieces[0].trimmingCharacters(in: .whitespaces)
                      .lowercased() == "content-length" else { continue }
            length = Int(pieces[1].trimmingCharacters(in: .whitespaces))
        }
        // No Content-Length: the body runs to close, which the caller
        // signals by parsing one last time on isComplete.
        let body = buffer[split.upperBound...]
        guard let length else { return HTTPResponse(status: status, body: Data(body)) }
        guard body.count >= length else { return nil }
        return HTTPResponse(status: status, body: Data(body.prefix(length)))
    }

    /// A manual `host:port` (or bare `host`) override, as typed by a
    /// human on a network where mDNS doesn't survive. `nil` when the
    /// text is empty or nonsense — the caller then stays on Bonjour.
    public static func parseEndpoint(_ text: String) -> (host: String, port: UInt16)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Bracketed IPv6 literal: [::1]:47824
        if trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") {
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let rest = trimmed[trimmed.index(after: close)...]
            guard !host.isEmpty else { return nil }
            if rest.isEmpty { return (host, defaultPort) }
            guard rest.hasPrefix(":"), let port = UInt16(rest.dropFirst()) else { return nil }
            return (host, port)
        }
        if let colon = trimmed.lastIndex(of: ":") {
            let host = String(trimmed[trimmed.startIndex..<colon])
            let portText = trimmed[trimmed.index(after: colon)...]
            // `host.contains(":")` guards a bare IPv6 literal ("fe80::1"),
            // which has no port and falls through to the bare-host case.
            if !host.isEmpty, !host.contains(":"), let port = UInt16(portText) {
                return (host, port)
            }
        }
        return (trimmed, defaultPort)
    }
}
