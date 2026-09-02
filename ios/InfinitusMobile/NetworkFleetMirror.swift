import Foundation
import Network
import InfinitusCore

/// The LAN transport (#9): finds the Mac's `_infinitus._tcp`
/// advertisement and fetches `GET /snapshot` over it. A free personal
/// team means no CloudKit, so the phone reads the fleet the same way it
/// would read a file — just over Wi-Fi, and only while on the same
/// network as the Mac.
///
/// One shared instance: MirrorModel and MobileUsage both pull snapshots,
/// and two browsers scanning for the same service would be waste.
actor NetworkFleetMirror: FleetMirror {
    static let shared = NetworkFleetMirror()

    /// Every endpoint a QR or the Settings field has ever added (#9 pair
    /// once, every route) — read fresh every fetch so a Settings edit
    /// takes effect at once. Replaces the old single `mirror_manual_endpoint`
    /// string (migrated below).
    static let manualKey = "mirror_manual_endpoints"
    /// The old single-endpoint key, migrated into `manualKey` once.
    static let legacyManualKey = "mirror_manual_endpoint"
    /// Whichever endpoint last answered — tried first next time, so a
    /// dead tunnel URL from a restarted Mac doesn't cost a timeout on
    /// every single refresh.
    static let lastGoodKey = "mirror_last_good_endpoint"
    /// The pairing token (#9 remote access) — every request carries it,
    /// Bonjour-discovered Macs included.
    static let tokenKey = "mirror_pair_token"
    /// Per-candidate connect timeout: several stored endpoints may be
    /// dead (a Mac off, a tunnel gone), so trying them all still has to
    /// land well inside one refresh.
    static let candidateTimeout: TimeInterval = 3

    /// One line for the Settings screen.
    private(set) var statusText = "looking for a Mac on this Wi-Fi…"

    private var browser: NWBrowser?
    private var endpoints: [NWEndpoint] = []
    /// The last snapshot that arrived — a dropped Wi-Fi then shows the
    /// staleness banner instead of falling back to "Waiting for the fleet".
    private var cached: MirrorSnapshot?

    /// Migrates the old single-endpoint string into the list, once. Both
    /// this actor and `MirrorModel` read defaults independently, so they
    /// share this one entry point rather than each rolling its own.
    static func migrateManualEndpointIfNeeded(_ defaults: UserDefaults = .standard) {
        guard let old = defaults.string(forKey: legacyManualKey), !old.isEmpty else { return }
        if ((defaults.array(forKey: manualKey) as? [String]) ?? []).isEmpty {
            defaults.set([old], forKey: manualKey)
        }
        defaults.removeObject(forKey: legacyManualKey)
    }

    /// The stored endpoint list, in the order the user (or a pairing QR)
    /// added them — migrating the legacy key first.
    static func storedEndpoints(_ defaults: UserDefaults = .standard) -> [String] {
        migrateManualEndpointIfNeeded(defaults)
        return (defaults.array(forKey: manualKey) as? [String]) ?? []
    }

    /// Stored endpoints with the last-successful one moved to the front —
    /// the order candidates are tried in, so a Mac that answered last
    /// time answers first this time.
    private func candidateEndpoints() -> [String] {
        var list = Self.storedEndpoints()
        if let lastGood = UserDefaults.standard.string(forKey: Self.lastGoodKey),
           let index = list.firstIndex(of: lastGood), index != 0 {
            list.remove(at: index)
            list.insert(lastGood, at: 0)
        }
        return list
    }

    func latest() async throws -> MirrorSnapshot? {
        let token = MirrorPairing.normalize(
            UserDefaults.standard.string(forKey: Self.tokenKey) ?? "")
        let stored = candidateEndpoints()
        var lastError: Error?
        // One short clause per route that failed, so the Settings line
        // says WHICH way in is dead — "offline" alone sent the user
        // rescanning when only the tunnel had changed.
        var failures: [String] = []
        for text in stored {
            guard let manual = MirrorTransport.parseEndpoint(text) else { continue }
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(manual.host),
                port: NWEndpoint.Port(rawValue: manual.port) ?? .any)
            do {
                let (data, _) = try await fetch(endpoint, path: MirrorTransport.snapshotPath,
                                                hostHeader: manual.host,
                                                useTLS: manual.useTLS, token: token,
                                                timeout: Self.candidateTimeout)
                let snapshot = try Self.decode(data)
                cached = snapshot
                UserDefaults.standard.set(text, forKey: Self.lastGoodKey)
                statusText = "\(snapshot.machineName) at \(text)"
                return snapshot
            } catch MirrorTransportError.http(401) {
                // The Mac is right there and refusing us: that's a pairing
                // problem, not a network one, and the fix is one field
                // away — stop trying the rest, they'd only repeat it.
                statusText = "pairing token required — scan the QR in the Mac's "
                    + "Devices settings"
                return cached
            } catch {
                lastError = error
                failures.append("\(Self.routeLabel(text)) \(Self.failureWord(error))")
            }
        }
        // No stored endpoint answered (or none is stored) — Bonjour is
        // the last resort, and only worth trying while on the LAN.
        startBrowsing()
        guard let discovered = await firstEndpoint() else {
            statusText = stored.isEmpty
                ? "no Mac found on this Wi-Fi"
                : "couldn't reach any saved Mac — " + failures.joined(separator: " · ")
            if cached == nil, let lastError, lastError is DecodingError { throw lastError }
            return cached
        }
        do {
            let (data, remote) = try await fetch(discovered, path: MirrorTransport.snapshotPath,
                                                 hostHeader: "infinitus",
                                                 useTLS: false, token: token,
                                                 timeout: Self.candidateTimeout)
            let snapshot = try Self.decode(data)
            cached = snapshot
            statusText = "\(snapshot.machineName) at \(remote)"
            return snapshot
        } catch MirrorTransportError.http(401) {
            statusText = "pairing token required — scan the QR in the Mac's "
                + "Devices settings"
            return cached
        } catch {
            failures.append("Wi-Fi discovery \(Self.failureWord(error))")
            statusText = (cached == nil ? "couldn't reach the Mac — " : "offline — ")
                + failures.joined(separator: " · ")
            // A decode failure is a real error; a network one just means
            // the Mac stepped away, and the cached fleet stays on screen.
            if cached == nil, error is DecodingError { throw error }
            return cached
        }
    }

    /// The session feed (#17 layer 1): same candidate/token/Host picking
    /// logic as `latest()`, factored into `fetchFromStored` so both share
    /// it — no snapshot-style caching here, a failed fetch just throws.
    func sessionTail(pid: Int32, limit: Int) async throws -> SessionFeed {
        let token = MirrorPairing.normalize(
            UserDefaults.standard.string(forKey: Self.tokenKey) ?? "")
        let path = MirrorTransport.sessionTailPath(pid: pid) + "?n=\(limit)"
        if let data = try await fetchFromStored(path: path, token: token, timeout: Self.candidateTimeout) {
            return try Self.decodeFeed(data)
        }
        startBrowsing()
        guard let discovered = await firstEndpoint() else { throw MirrorTransportError.timedOut }
        let (data, _) = try await fetch(discovered, path: path, hostHeader: "infinitus",
                                        useTLS: false, token: token, timeout: Self.candidateTimeout)
        return try Self.decodeFeed(data)
    }

    /// Tries every stored endpoint (last-good first), same as `latest()`'s
    /// own loop — `nil` means none of them answered for network reasons;
    /// a bad pairing token still throws, since that's equally actionable
    /// for either caller.
    private func fetchFromStored(path: String, token: String, timeout: TimeInterval,
                                 method: String = "GET", body: Data? = nil) async throws -> Data? {
        for text in candidateEndpoints() {
            guard let manual = MirrorTransport.parseEndpoint(text) else { continue }
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(manual.host),
                port: NWEndpoint.Port(rawValue: manual.port) ?? .any)
            do {
                let (data, _) = try await fetch(endpoint, path: path, hostHeader: manual.host,
                                                useTLS: manual.useTLS, token: token, timeout: timeout,
                                                method: method, body: body)
                UserDefaults.standard.set(text, forKey: Self.lastGoodKey)
                return data
            } catch MirrorTransportError.http(401) {
                throw MirrorTransportError.http(401)
            } catch {
                continue
            }
        }
        return nil
    }

    /// Layer 2 of #17: posts a reply or a key press into a session's
    /// terminal. Same candidate/token/discovery path as `sessionTail`;
    /// unlike the feed, a Mac that's simply offline has nothing sensible
    /// to fall back to, so every failure throws.
    func sessionInput(pid: Int32, request: SessionInput.Request) async throws -> SessionInput.Reply {
        let token = MirrorPairing.normalize(
            UserDefaults.standard.string(forKey: Self.tokenKey) ?? "")
        let path = MirrorTransport.sessionInputPath(pid: pid)
        let body = try JSONEncoder().encode(request)
        if let data = try await fetchFromStored(path: path, token: token, timeout: Self.candidateTimeout,
                                                method: "POST", body: body) {
            return try JSONDecoder().decode(SessionInput.Reply.self, from: data)
        }
        startBrowsing()
        guard let discovered = await firstEndpoint() else { throw MirrorTransportError.timedOut }
        let (data, _) = try await fetch(discovered, path: path, hostHeader: "infinitus",
                                        useTLS: false, token: token, timeout: Self.candidateTimeout,
                                        method: "POST", body: body)
        return try JSONDecoder().decode(SessionInput.Reply.self, from: data)
    }

    /// `192.168.2.36:47824` / `abc.trycloudflare.com` — the stored text
    /// without its scheme, short enough for one status line.
    private static func routeLabel(_ text: String) -> String {
        guard let manual = MirrorTransport.parseEndpoint(text) else { return text }
        let standardPort = manual.useTLS ? manual.port == 443 : manual.port == 80
        return standardPort ? manual.host : "\(manual.host):\(manual.port)"
    }

    private static func failureWord(_ error: Error) -> String {
        switch error {
        case MirrorTransportError.http(let status): return "answered \(status)"
        case MirrorTransportError.timedOut, MirrorTransportError.closed: return "didn't answer"
        case is DecodingError: return "sent something unreadable"
        default: return "unreachable"
        }
    }

    private static func decode(_ data: Data) throws -> MirrorSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MirrorSnapshot.self, from: data)
    }

    private static func decodeFeed(_ data: Data) throws -> SessionFeed {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SessionFeed.self, from: data)
    }

    // MARK: - Discovery

    private func startBrowsing() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = false
        let browser = NWBrowser(
            for: .bonjour(type: MirrorTransport.bonjourType, domain: nil),
            using: params)
        browser.browseResultsChangedHandler = { results, _ in
            let found = results.map(\.endpoint)
            Task { await self.apply(endpoints: found) }
        }
        browser.stateUpdateHandler = { state in
            guard case .failed(let error) = state else { return }
            Task { await self.browseFailed(error) }
        }
        self.browser = browser
        browser.start(queue: .global(qos: .utility))
    }

    private func apply(endpoints: [NWEndpoint]) {
        self.endpoints = endpoints
    }

    private func browseFailed(_ error: NWError) {
        browser?.cancel()
        browser = nil
        statusText = "discovery failed: \(error.localizedDescription)"
    }

    /// Discovery takes a moment; without a short wait the very first
    /// refresh would come up empty and the screen would sit on its empty
    /// state for a whole 10s poll.
    private func firstEndpoint(timeout: TimeInterval = 2) async -> NWEndpoint? {
        let deadline = Date().addingTimeInterval(timeout)
        while endpoints.isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return endpoints.first
    }

    // MARK: - Fetch

    /// Returns the response body and the resolved `host:port` it came
    /// from (the Bonjour endpoint alone never names a port). `method`/
    /// `body` default to a plain `GET` (#17 layer 2's `POST
    /// /sessions/<pid>/input` is the only other caller).
    private func fetch(_ endpoint: NWEndpoint, path: String, hostHeader: String, useTLS: Bool,
                       token: String, timeout: TimeInterval = 5,
                       method: String = "GET", body: Data? = nil) async throws -> (Data, String) {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Int(timeout)
        // A quick tunnel answers on 443 with a real certificate; the LAN
        // and tailnet paths stay plain TCP.
        let params = useTLS ? NWParameters(tls: NWProtocolTLS.Options(), tcp: tcp)
            : NWParameters(tls: nil, tcp: tcp)
        let connection = NWConnection(to: endpoint, using: params)
        let queue = DispatchQueue(label: "com.huuloc.infinitus.mobile.mirror")
        let once = ContinuationOnce()
        return try await withCheckedThrowingContinuation { continuation in
            once.attach(continuation) { connection.cancel() }
            // Belt and braces: a half-open TCP connection can otherwise
            // hang past the connect timeout with no bytes ever arriving.
            queue.asyncAfter(deadline: .now() + timeout + 2) {
                once.finish(.failure(MirrorTransportError.timedOut))
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let remote = connection.currentPath?.remoteEndpoint
                        .map(String.init(describing:)) ?? String(describing: endpoint)
                    var head = "\(method) \(path) HTTP/1.1\r\n"
                        + "Host: \(hostHeader)\r\n"
                        + "Authorization: Bearer \(token)\r\n"
                    if let body {
                        head += "Content-Type: application/json\r\n"
                        head += "Content-Length: \(body.count)\r\n"
                    }
                    head += "Connection: close\r\n\r\n"
                    var request = Data(head.utf8)
                    if let body { request.append(body) }
                    connection.send(content: request,
                                    completion: .contentProcessed { error in
                        if let error { once.finish(.failure(error)) }
                    })
                    Self.receive(connection, buffer: Data(), remote: remote, once: once)
                case .failed(let error):
                    once.finish(.failure(error))
                case .cancelled:
                    once.finish(.failure(MirrorTransportError.closed))
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private static func receive(_ connection: NWConnection, buffer: Data,
                                remote: String, once: ContinuationOnce) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let response = MirrorTransport.parseResponse(buffer) {
                guard response.status == 200 else {
                    once.finish(.failure(MirrorTransportError.http(response.status)))
                    return
                }
                once.finish(.success((response.body, remote)))
                return
            }
            if let error {
                once.finish(.failure(error))
                return
            }
            guard !isComplete else {
                once.finish(.failure(MirrorTransportError.closed))
                return
            }
            receive(connection, buffer: buffer, remote: remote, once: once)
        }
    }
}

enum MirrorTransportError: LocalizedError {
    case http(Int)
    case closed
    case timedOut

    var errorDescription: String? {
        switch self {
        case .http(let status): return "the Mac answered \(status)"
        case .closed: return "the Mac closed the connection"
        case .timedOut: return "the Mac didn't answer"
        }
    }
}

/// Resumes a checked continuation exactly once, from whichever network
/// callback gets there first, and tears the connection down after.
private final class ContinuationOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, String), Error>?
    private var cleanup: (() -> Void)?

    func attach(_ continuation: CheckedContinuation<(Data, String), Error>,
                cleanup: @escaping () -> Void) {
        lock.lock()
        self.continuation = continuation
        self.cleanup = cleanup
        lock.unlock()
    }

    func finish(_ result: Result<(Data, String), Error>) {
        lock.lock()
        let continuation = self.continuation
        let cleanup = self.cleanup
        self.continuation = nil
        self.cleanup = nil
        lock.unlock()
        guard let continuation else { return }
        continuation.resume(with: result)
        cleanup?()
    }
}

/// Tries each mirror in turn and takes the first snapshot anyone has —
/// LAN first, the Documents copy as the offline fallback (#9).
struct ChainFleetMirror: FleetMirror {
    let mirrors: [FleetMirror]

    func latest() async throws -> MirrorSnapshot? {
        var firstError: Error?
        for mirror in mirrors {
            do {
                if let snapshot = try await mirror.latest() { return snapshot }
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
        return nil
    }
}
