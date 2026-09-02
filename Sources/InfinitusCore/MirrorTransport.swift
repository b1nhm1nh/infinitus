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
    /// The per-session feed route (#17 layer 1): `GET /sessions/<pid>/tail`.
    public static func sessionTailPath(pid: Int32) -> String { "/sessions/\(pid)/tail" }
    /// The `pid` out of a request path, when it matches
    /// `/sessions/<pid>/tail` exactly — `nil` for anything else,
    /// including a non-numeric pid.
    public static func sessionTailPid(_ path: String) -> Int32? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[0] == "sessions", parts[2] == "tail" else { return nil }
        return Int32(parts[1])
    }
    /// Query parameter carrying the item limit for the tail route.
    public static let tailLimitQueryName = "n"
    /// Query parameter carrying the pairing token when a header can't
    /// (a QR-pasted URL opened in a browser, `curl "…?t=TOKEN"`).
    public static let tokenQueryName = "t"
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

    /// A whole request head: the request line plus every header, which is
    /// what auth needs (the token may ride in `Authorization`). `nil`
    /// while the head is still arriving — headers land in arbitrary
    /// chunks just like bodies do.
    public struct Request: Sendable, Equatable {
        public let method: String
        /// The raw request target, query string and all.
        public let target: String
        /// Header names lowercased; HTTP says they're case-insensitive.
        public let headers: [String: String]

        public init(method: String, target: String, headers: [String: String]) {
            self.method = method
            self.target = target
            self.headers = headers
        }

        /// The target with any `?query` stripped — what routing compares.
        public var path: String {
            guard let mark = target.firstIndex(of: "?") else { return target }
            return String(target[target.startIndex..<mark])
        }

        /// A percent-decoded query parameter.
        public func query(_ name: String) -> String? {
            guard let mark = target.firstIndex(of: "?") else { return nil }
            for pair in target[target.index(after: mark)...].split(separator: "&") {
                let halves = pair.split(separator: "=", maxSplits: 1)
                guard halves.first.map(String.init) == name else { continue }
                let raw = halves.count == 2 ? String(halves[1]) : ""
                return raw.replacingOccurrences(of: "+", with: " ")
                    .removingPercentEncoding ?? raw
            }
            return nil
        }
    }

    public static func parseRequest(_ data: Data) -> Request? {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[data.startIndex..<split.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let request = lines.removeFirst().split(separator: " ",
                                                omittingEmptySubsequences: true)
        guard request.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            let halves = line.split(separator: ":", maxSplits: 1)
            guard halves.count == 2 else { continue }
            headers[halves[0].trimmingCharacters(in: .whitespaces).lowercased()] =
                halves[1].trimmingCharacters(in: .whitespaces)
        }
        return Request(method: String(request[0]), target: String(request[1]),
                       headers: headers)
    }

    // MARK: - Pairing check (#9 remote access)

    /// The token a request carries: `Authorization: Bearer <token>` or,
    /// for URLs pasted from a QR, `?t=<token>`.
    public static func presentedToken(_ request: Request) -> String? {
        if let header = request.headers["authorization"] {
            let parts = header.split(separator: " ", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "bearer" {
                return String(parts[1])
            }
        }
        return request.query(tokenQueryName)
    }

    /// Whether a request may read the snapshot. An empty expected token
    /// denies everything: a server without a pairing token is not a
    /// server anyone is allowed to read.
    public static func isAuthorized(_ request: Request, token: String) -> Bool {
        let expected = MirrorPairing.normalize(token)
        guard !expected.isEmpty,
              let presented = presentedToken(request) else { return false }
        return MirrorPairing.matches(MirrorPairing.normalize(presented), expected)
    }

    public static func response(status: Int, reason: String,
                                contentType: String, body: Data,
                                extraHeaders: [String: String] = [:]) -> Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        for (name, value) in extraHeaders.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
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

    /// No pairing token, or the wrong one (#9 remote access). The realm
    /// names the app so a browser's prompt says where the token comes from.
    public static func unauthorizedResponse() -> Data {
        response(status: 401, reason: "Unauthorized", contentType: "text/plain",
                 body: Data("pairing token required\n".utf8),
                 extraHeaders: ["WWW-Authenticate": "Bearer realm=\"infinitus\""])
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

    /// Where the phone should connect: a manual `host:port` as typed by
    /// a human on a network where mDNS doesn't survive, or a whole URL
    /// as carried by a pairing QR (`https://x.trycloudflare.com` →
    /// port 443 over TLS).
    public struct Endpoint: Sendable, Equatable {
        public let host: String
        public let port: UInt16
        /// The connection speaks TLS — true only for an `https://` URL.
        public let useTLS: Bool

        public init(host: String, port: UInt16, useTLS: Bool = false) {
            self.host = host
            self.port = port
            self.useTLS = useTLS
        }

        /// The `http(s)://host:port` form a QR encodes.
        public var urlText: String {
            let scheme = useTLS ? "https" : "http"
            let bracketed = host.contains(":") ? "[\(host)]" : host
            let implied: UInt16 = useTLS ? 443 : 80
            return port == implied ? "\(scheme)://\(bracketed)"
                : "\(scheme)://\(bracketed):\(port)"
        }
    }

    /// `nil` when the text is empty or nonsense — the caller then stays
    /// on Bonjour.
    public static func parseEndpoint(_ text: String) -> Endpoint? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var tls = false
        var defaultForScheme = defaultPort
        for (scheme, secure) in [("https://", true), ("http://", false)] {
            guard trimmed.lowercased().hasPrefix(scheme) else { continue }
            trimmed = String(trimmed.dropFirst(scheme.count))
            tls = secure
            // A URL without a port means the scheme's own port, not the
            // Bonjour default: tunnels answer on 443.
            defaultForScheme = secure ? 443 : 80
            break
        }
        // A pasted URL can carry a path ("…/snapshot") or a query.
        if let cut = trimmed.firstIndex(where: { $0 == "/" || $0 == "?" }) {
            trimmed = String(trimmed[trimmed.startIndex..<cut])
        }
        guard !trimmed.isEmpty else { return nil }
        // Bracketed IPv6 literal: [::1]:47824
        if trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") {
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let rest = trimmed[trimmed.index(after: close)...]
            guard !host.isEmpty else { return nil }
            if rest.isEmpty { return Endpoint(host: host, port: defaultForScheme, useTLS: tls) }
            guard rest.hasPrefix(":"), let port = UInt16(rest.dropFirst()) else { return nil }
            return Endpoint(host: host, port: port, useTLS: tls)
        }
        if let colon = trimmed.lastIndex(of: ":") {
            let host = String(trimmed[trimmed.startIndex..<colon])
            let portText = trimmed[trimmed.index(after: colon)...]
            // `host.contains(":")` guards a bare IPv6 literal ("fe80::1"),
            // which has no port and falls through to the bare-host case.
            if !host.isEmpty, !host.contains(":"), let port = UInt16(portText) {
                return Endpoint(host: host, port: port, useTLS: tls)
            }
        }
        return Endpoint(host: trimmed, port: defaultForScheme, useTLS: tls)
    }
}
