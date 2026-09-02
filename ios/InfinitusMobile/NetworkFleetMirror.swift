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

    /// Manual `host:port` for networks where mDNS doesn't survive; read
    /// fresh every fetch so the Settings field takes effect at once.
    static let manualKey = "mirror_manual_endpoint"

    /// One line for the Settings screen.
    private(set) var statusText = "looking for a Mac on this Wi-Fi…"

    private var browser: NWBrowser?
    private var endpoints: [NWEndpoint] = []
    /// The last snapshot that arrived — a dropped Wi-Fi then shows the
    /// staleness banner instead of falling back to "Waiting for the fleet".
    private var cached: MirrorSnapshot?

    func latest() async throws -> MirrorSnapshot? {
        let manual = UserDefaults.standard.string(forKey: Self.manualKey)
            .flatMap(MirrorTransport.parseEndpoint)
        let endpoint: NWEndpoint
        if let manual {
            endpoint = .hostPort(host: NWEndpoint.Host(manual.host),
                                 port: NWEndpoint.Port(rawValue: manual.port) ?? .any)
        } else {
            startBrowsing()
            guard let discovered = await firstEndpoint() else {
                statusText = "no Mac found on this Wi-Fi"
                return cached
            }
            endpoint = discovered
        }
        do {
            let (data, remote) = try await fetch(endpoint)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(MirrorSnapshot.self, from: data)
            cached = snapshot
            statusText = "\(snapshot.machineName) at \(remote)"
            return snapshot
        } catch {
            statusText = cached == nil
                ? "couldn't reach the Mac: \(error.localizedDescription)"
                : "offline — showing the last snapshot"
            // A decode failure is a real error; a network one just means
            // the Mac stepped away, and the cached fleet stays on screen.
            if cached == nil, error is DecodingError { throw error }
            return cached
        }
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
    /// from (the Bonjour endpoint alone never names a port).
    private func fetch(_ endpoint: NWEndpoint) async throws -> (Data, String) {
        let params = NWParameters.tcp
        (params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?
            .connectionTimeout = 5
        let connection = NWConnection(to: endpoint, using: params)
        let queue = DispatchQueue(label: "com.huuloc.infinitus.mobile.mirror")
        let once = ContinuationOnce()
        return try await withCheckedThrowingContinuation { continuation in
            once.attach(continuation) { connection.cancel() }
            // Belt and braces: a half-open TCP connection can otherwise
            // hang past the connect timeout with no bytes ever arriving.
            queue.asyncAfter(deadline: .now() + 8) {
                once.finish(.failure(MirrorTransportError.timedOut))
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let remote = connection.currentPath?.remoteEndpoint
                        .map(String.init(describing:)) ?? String(describing: endpoint)
                    let request = "GET \(MirrorTransport.snapshotPath) HTTP/1.1\r\n"
                        + "Host: infinitus\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(request.utf8),
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
