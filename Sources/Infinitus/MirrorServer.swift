import Foundation
import Network
import InfinitusCore

/// The latest encoded snapshot, shared between the exporter actor (which
/// writes it) and the NWConnection handlers on the network queue (which
/// read it). A lock, not an actor: the connection callbacks are
/// synchronous and must answer without hopping executors.
final class MirrorPayloadBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    var latest: Data? {
        lock.lock(); defer { lock.unlock() }
        return data
    }

    func set(_ new: Data) {
        lock.lock(); data = new; lock.unlock()
    }
}

/// The pairing token, shared the same way for the same reason: the
/// connection handlers read it on the network queue, and "Regenerate"
/// writes it from the main actor without restarting the listener.
final class MirrorTokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var token = ""

    var current: String {
        lock.lock(); defer { lock.unlock() }
        return token
    }

    func set(_ new: String) {
        lock.lock(); token = new; lock.unlock()
    }
}

/// The `/sessions/<pid>/tail` handler (#17 layer 1), boxed the same way
/// as payload/token: AppModel sets it from the main actor, the
/// connection handlers call it from the network queue. The closure does
/// its own file read (`ClaudeSessions.list` + `SessionFeedReader.read`)
/// on that queue — off the main actor, same as every other route here.
final class MirrorSessionFeedBox: @unchecked Sendable {
    typealias Provider = @Sendable (_ pid: Int32, _ limit: Int, _ since: String?, _ wait: TimeInterval) -> Data?
    private let lock = NSLock()
    private var provider: Provider?

    func set(_ new: @escaping Provider) {
        lock.lock(); provider = new; lock.unlock()
    }

    /// May block for up to `wait` seconds (the long-poll) — call it off
    /// the network queue when `wait > 0`.
    func call(_ pid: Int32, _ limit: Int, since: String? = nil, wait: TimeInterval = 0) -> Data? {
        lock.lock(); let current = provider; lock.unlock()
        return current?(pid, limit, since, wait)
    }
}

/// The `POST /activities/token` handler (Live Activity pushes): the
/// phone's APNs tokens, handed to AppModel's pusher on the main actor.
/// The `/sessions/<pid>/images/<id>` handler (phone thumbnails): the
/// image bytes and content type, nil for 404. Reads a transcript tail
/// and scales an image, so the route runs it off the network queue.
final class MirrorSessionImageBox: @unchecked Sendable {
    typealias Provider = @Sendable (_ pid: Int32, _ id: String) -> (data: Data, contentType: String)?
    private let lock = NSLock()
    private var provider: Provider?

    func set(_ new: @escaping Provider) {
        lock.lock(); provider = new; lock.unlock()
    }

    func call(_ pid: Int32, _ id: String) -> (data: Data, contentType: String)? {
        lock.lock(); let current = provider; lock.unlock()
        return current?(pid, id)
    }
}

final class MirrorActivityTokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (@Sendable (ActivityPushRegistration) -> Void)?

    func set(_ new: @escaping @Sendable (ActivityPushRegistration) -> Void) {
        lock.lock(); sink = new; lock.unlock()
    }

    func call(_ registration: ActivityPushRegistration) {
        lock.lock(); let current = sink; lock.unlock()
        current?(registration)
    }
}

/// The `POST /crashes` handler: a phone's crash report, handed to
/// AppModel's store on the main actor.
final class MirrorCrashBox: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (@Sendable (CrashReport) -> Void)?

    func set(_ new: @escaping @Sendable (CrashReport) -> Void) {
        lock.lock(); sink = new; lock.unlock()
    }

    func call(_ report: CrashReport) {
        lock.lock(); let current = sink; lock.unlock()
        current?(report)
    }
}

/// The `POST /sessions/<pid>/input` handler (#17 layer 2), boxed the
/// same way as `sessionFeed`: AppModel sets it once from the main actor,
/// the connection handlers call it from the network queue. `nil` means
/// "no such pid" (404); the closure itself does the PTY/socket delivery
/// and its own logging.
/// AWS sign-in from the phone (AwsLogin.swift): start / code handlers.
final class MirrorAwsLoginBox: @unchecked Sendable {
    private let lock = NSLock()
    private var start: (@Sendable (AwsLogin.StartRequest) async -> AwsLogin.Reply)?
    private var code: (@Sendable (AwsLogin.CodeRequest) async -> AwsLogin.Reply)?
    private var callback: (@Sendable (AwsLogin.CallbackRequest) async -> AwsLogin.Reply)?

    func set(start: @escaping @Sendable (AwsLogin.StartRequest) async -> AwsLogin.Reply,
             code: @escaping @Sendable (AwsLogin.CodeRequest) async -> AwsLogin.Reply,
             callback: @escaping @Sendable (AwsLogin.CallbackRequest) async -> AwsLogin.Reply) {
        lock.lock(); self.start = start; self.code = code; self.callback = callback; lock.unlock()
    }

    private func handlers() -> ((@Sendable (AwsLogin.StartRequest) async -> AwsLogin.Reply)?,
                                (@Sendable (AwsLogin.CodeRequest) async -> AwsLogin.Reply)?,
                                (@Sendable (AwsLogin.CallbackRequest) async -> AwsLogin.Reply)?) {
        lock.lock(); defer { lock.unlock() }
        return (start, code, callback)
    }

    func callCallback(_ r: AwsLogin.CallbackRequest) async -> AwsLogin.Reply? {
        guard let f = handlers().2 else { return nil }
        return await f(r)
    }

    func callStart(_ r: AwsLogin.StartRequest) async -> AwsLogin.Reply? {
        guard let f = handlers().0 else { return nil }
        return await f(r)
    }

    func callCode(_ r: AwsLogin.CodeRequest) async -> AwsLogin.Reply? {
        guard let f = handlers().1 else { return nil }
        return await f(r)
    }
}

/// Where `POST /sessions/<pid>/input` deliveries run, one at a time.
private let mirrorInputQueue = DispatchQueue(label: "com.huuloc.infinitus.mirror-input", qos: .userInitiated)

final class MirrorSessionInputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var provider: (@Sendable (Int32, SessionInput.Request) -> SessionInput.Reply?)?

    func set(_ new: @escaping @Sendable (Int32, SessionInput.Request) -> SessionInput.Reply?) {
        lock.lock(); provider = new; lock.unlock()
    }

    func call(_ pid: Int32, _ request: SessionInput.Request) -> SessionInput.Reply? {
        lock.lock(); let current = provider; lock.unlock()
        return current?(pid, request)
    }
}

/// Serves the fleet snapshot to the phone (#9): one Bonjour advertised
/// (`_infinitus._tcp`) TCP listener answering `GET /snapshot` with the
/// exact bytes MirrorExporter wrote. Off by default behind the Sync
/// pane's toggle.
///
/// Every request must carry the pairing token — `Authorization: Bearer
/// <token>` or `?t=<token>` — else 401, before routing. That is what
/// makes the same listener safe to reach from a tailnet or a Cloudflare
/// quick tunnel: it binds every interface either way, and the token is
/// the only lock.
@MainActor
final class MirrorServer: ObservableObject {
    /// The bound port, once the listener is ready.
    @Published private(set) var port: UInt16?
    /// One line for the Settings pane.
    @Published private(set) var status: String?
    /// When a phone last fetched with the right token — the walkthrough's
    /// "paired" check. Session-only; a relaunch starts unpaired.
    @Published private(set) var lastServed: Date?
    /// Every phone that fetched with the right token this session, newest
    /// first (user 2026-09-03: "show active/connected devices").
    @Published private(set) var clients: [MirrorClient] = []

    /// Handed to MirrorExporter so every export lands here too.
    let payload = MirrorPayloadBox()
    /// Read by the connection handlers; written by AppModel on regenerate.
    let token = MirrorTokenBox()
    /// Answers `/sessions/<pid>/tail`; set by AppModel once at start.
    let sessionFeed = MirrorSessionFeedBox()
    /// Answers `POST /activities/token`; set by AppModel once at start.
    let activityTokens = MirrorActivityTokenBox()
    /// Answers `POST /sessions/<pid>/input` (#17 layer 2); set by AppModel
    /// once at start.
    let sessionInput = MirrorSessionInputBox()
    /// Answers `/sessions/<pid>/images/<id>`; set by AppModel once at start.
    let sessionImage = MirrorSessionImageBox()
    let awsLogin = MirrorAwsLoginBox()
    /// Answers `POST /crashes`; set by AppModel once at start.
    let crashes = MirrorCrashBox()
    /// Event-log sink (icon, text), set by AppModel.
    var log: ((String, String) -> Void)?
    /// Fires with the bound port once the listener is up — the quick
    /// tunnel can only be pointed at a port that exists.
    var onReady: ((UInt16) -> Void)?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.huuloc.infinitus.mirror-server")

    func start(machineName: String, token: String) {
        self.token.set(token)
        guard listener == nil else { return }
        // The last export renders immediately: a phone that asks before
        // the first refresh of this launch still gets a fleet.
        if payload.latest == nil,
           let data = try? Data(contentsOf: MirrorExporter.url) {
            payload.set(data)
        }
        status = "starting…"
        listen(on: MirrorTransport.defaultPort, name: machineName)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
        status = nil
    }

    private func listen(on rawPort: UInt16, name: String) {
        let params = NWParameters.tcp
        // Toggling the server off and on shouldn't trip over TIME_WAIT.
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = false
        // IPv4 socket, not the dual-stack IPv6 wildcard: a connection to
        // this Mac's own tailnet address never reached the v6 socket
        // (Tailscale's utun hands IPv4 to IPv4 sockets only — probed
        // 2026-09-02, LAN fine both ways, 100.x only with v4).
        (params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let endpointPort = rawPort == 0 ? NWEndpoint.Port.any
            : NWEndpoint.Port(rawValue: rawPort) ?? .any
        guard let listener = try? NWListener(using: params, on: endpointPort) else {
            status = "couldn't open a port"
            return
        }
        listener.service = NWListener.Service(name: name,
                                              type: MirrorTransport.bonjourType)
        let payload = self.payload
        let token = self.token
        let sessionFeed = self.sessionFeed
        let sessionInput = self.sessionInput
        let sessionImage = self.sessionImage
        let activityTokens = self.activityTokens
        let awsLogin = self.awsLogin
        let crashes = self.crashes
        let served: @Sendable (MirrorTransport.Request) -> Void = { [weak self] request in
            let client = MirrorClient(request: request)
            Task { @MainActor in
                guard let self else { return }
                self.lastServed = client.lastSeen
                self.clients = MirrorClient.merge(client, into: self.clients)
            }
        }
        listener.newConnectionHandler = { [queue] connection in
            Self.serve(connection, payload: payload, token: token, sessionFeed: sessionFeed,
                       sessionInput: sessionInput, sessionImage: sessionImage, activityTokens: activityTokens, crashes: crashes,
                       awsLogin: awsLogin, queue: queue, onServed: served)
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.handle(state, wasFixedPort: rawPort != 0, name: name) }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    private func handle(_ state: NWListener.State, wasFixedPort: Bool, name: String) {
        switch state {
        case .ready:
            let bound = listener?.port?.rawValue
            port = bound
            status = "serving \(name) on port \(bound.map(String.init) ?? "?")"
            log?("📱", "phone companion listening on port \(bound.map(String.init) ?? "?")")
            if let bound { onReady?(bound) }
        case .failed(let error):
            listener?.cancel()
            listener = nil
            // The fixed port is only a convenience for the phone's manual
            // override — if something else holds it, take any port and
            // let Bonjour carry the number.
            if wasFixedPort, case .posix(.EADDRINUSE) = error {
                listen(on: 0, name: name)
            } else {
                port = nil
                status = "failed: \(error.localizedDescription)"
                log?("⚠️", "phone companion failed: \(error.localizedDescription)")
            }
        case .cancelled:
            port = nil
        default:
            break
        }
    }

    // MARK: - Connection handling (network queue)

    private nonisolated static func serve(_ connection: NWConnection,
                                          payload: MirrorPayloadBox,
                                          token: MirrorTokenBox,
                                          sessionFeed: MirrorSessionFeedBox,
                                          sessionInput: MirrorSessionInputBox,
                                            sessionImage: MirrorSessionImageBox,
                                          activityTokens: MirrorActivityTokenBox, crashes: MirrorCrashBox,
                                          awsLogin: MirrorAwsLoginBox,
                                          queue: DispatchQueue,
                                          onServed: @escaping @Sendable (MirrorTransport.Request) -> Void) {
        connection.start(queue: queue)
        receive(connection, buffer: Data(), payload: payload, token: token,
               sessionFeed: sessionFeed, sessionInput: sessionInput, sessionImage: sessionImage,
               activityTokens: activityTokens, crashes: crashes, awsLogin: awsLogin, onServed: onServed)
    }

    private nonisolated static func receive(_ connection: NWConnection,
                                            buffer: Data,
                                            payload: MirrorPayloadBox,
                                            token: MirrorTokenBox,
                                            sessionFeed: MirrorSessionFeedBox,
                                            sessionInput: MirrorSessionInputBox,
                                            sessionImage: MirrorSessionImageBox,
                                            activityTokens: MirrorActivityTokenBox, crashes: MirrorCrashBox,
                                            awsLogin: MirrorAwsLoginBox,
                                            onServed: @escaping @Sendable (MirrorTransport.Request) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
            data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            // The head alone (token included — it rides in a header or the
            // query, never the body) is enough to both pick the route's
            // body cap and reject an unpaired caller before buffering a
            // single byte of a body it was never going to be allowed to
            // send — this listener may be tunnel-exposed, and the
            // attachments route's 24 MiB cap is not something to hold open
            // for a caller that was always going to get a 401
            // (2026-09-03 attachments).
            let head = MirrorTransport.parseRequest(buffer)
            if let head, !MirrorTransport.isAuthorized(head, token: token.current) {
                connection.send(content: MirrorTransport.unauthorizedResponse(),
                                completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            let cap = head.map {
                MirrorTransport.bodyCap(method: $0.method, path: $0.path)
            } ?? MirrorTransport.defaultBodyCap
            // The whole head AND, when there is one, the whole body — the
            // input route's JSON body arrives in arbitrary chunks just
            // like everything else. Auth was already checked off the head
            // above; the check below stays as the route dispatch's own
            // defense in depth (e.g. a token regenerated mid-request).
            if let request = MirrorTransport.parseRequestWithBody(buffer, bodyCap: cap) {
                let response: Data
                if !MirrorTransport.isAuthorized(request, token: token.current) {
                    response = MirrorTransport.unauthorizedResponse()
                } else if request.method == "GET",
                          request.path == MirrorTransport.snapshotPath {
                    response = payload.latest.map(MirrorTransport.snapshotResponse)
                        ?? MirrorTransport.unavailableResponse()
                    onServed(request)
                } else if request.method == "GET",
                          let pid = MirrorTransport.sessionTailPid(request.path) {
                    let limit = request.query(MirrorTransport.tailLimitQueryName).flatMap(Int.init) ?? 30
                    let since = request.query(MirrorTransport.tailSinceQueryName)
                    let wait = request.query(MirrorTransport.tailWaitQueryName).flatMap(Double.init) ?? 0
                    // Off this queue either way: a long-poll sleeps until
                    // the transcript moves, and even the plain form reads
                    // a 256 KiB tail — every connection shares this queue,
                    // so nothing that takes time may run on it.
                    DispatchQueue.global(qos: .utility).async {
                        let data = sessionFeed.call(pid, limit, since: since, wait: wait)
                        let response = data.map(MirrorTransport.snapshotResponse)
                            ?? MirrorTransport.notFoundResponse()
                        onServed(request)
                        connection.send(content: response,
                                        completion: .contentProcessed { _ in connection.cancel() })
                    }
                    return
                } else if request.method == "GET",
                          let ref = MirrorTransport.sessionImageRef(request.path) {
                    // A transcript tail read and an image decode: off this queue.
                    DispatchQueue.global(qos: .utility).async {
                        let response = sessionImage.call(ref.pid, ref.id)
                            .map { MirrorTransport.imageResponse($0.data, contentType: $0.contentType) }
                            ?? MirrorTransport.notFoundResponse()
                        onServed(request)
                        connection.send(content: response,
                                        completion: .contentProcessed { _ in connection.cancel() })
                    }
                    return
                } else if request.method == "POST",
                          let pid = MirrorTransport.sessionInputPid(request.path) {
                    guard let decoded = try? JSONDecoder().decode(SessionInput.Request.self, from: request.body)
                    else {
                        connection.send(content: MirrorTransport.badRequestResponse(),
                                        completion: .contentProcessed { _ in connection.cancel() })
                        return
                    }
                    // Delivery spawns `ps` and sleeps through the terminal's
                    // settle waits (a second each) — on this queue that
                    // stalled the phone's own long-poll and the snapshot
                    // behind every send (user 2026-09-04 "sending and
                    // receiving are not responsive"). Its own SERIAL queue,
                    // not the global pool: two sends in a row must land
                    // one after the other, never interleave keystrokes.
                    mirrorInputQueue.async {
                        let response = sessionInput.call(pid, decoded)
                            .flatMap { try? JSONEncoder().encode($0) }
                            .map(MirrorTransport.jsonResponse)
                            ?? MirrorTransport.notFoundResponse()
                        onServed(request)
                        connection.send(content: response,
                                        completion: .contentProcessed { _ in connection.cancel() })
                    }
                    return
                } else if request.method == "POST",
                          [AwsLogin.startPath, AwsLogin.codePath, AwsLogin.callbackPath].contains(request.path) {
                    // The code / callback never leaves this path: decoded,
                    // handed to the runner, gone. Async: the reply waits
                    // for the runner actor, so it runs off this queue.
                    let decoder = JSONDecoder()
                    let startBody = request.path == AwsLogin.startPath ? try? decoder.decode(AwsLogin.StartRequest.self, from: request.body) : nil
                    let codeBody = request.path == AwsLogin.codePath ? try? decoder.decode(AwsLogin.CodeRequest.self, from: request.body) : nil
                    let callbackBody = request.path == AwsLogin.callbackPath ? try? decoder.decode(AwsLogin.CallbackRequest.self, from: request.body) : nil
                    guard startBody != nil || codeBody != nil || callbackBody != nil else {
                        connection.send(content: MirrorTransport.badRequestResponse(),
                                        completion: .contentProcessed { _ in connection.cancel() })
                        return
                    }
                    Task {
                        let reply: AwsLogin.Reply?
                        if let startBody { reply = await awsLogin.callStart(startBody) }
                        else if let codeBody { reply = await awsLogin.callCode(codeBody) }
                        else if let callbackBody { reply = await awsLogin.callCallback(callbackBody) }
                        else { reply = nil }
                        let response = reply.flatMap { try? JSONEncoder().encode($0) }
                            .map(MirrorTransport.jsonResponse) ?? MirrorTransport.notFoundResponse()
                        onServed(request)
                        connection.send(content: response,
                                        completion: .contentProcessed { _ in connection.cancel() })
                    }
                    return
                } else if request.method == "POST", request.path == MirrorTransport.crashesPath {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    if request.body.count <= 2 * CrashReport.rawCap,
                       let report = try? decoder.decode(CrashReport.self, from: request.body) {
                        crashes.call(report)
                        response = MirrorTransport.jsonResponse(Data(#"{"ok":true}"#.utf8))
                        onServed(request)
                    } else {
                        response = MirrorTransport.badRequestResponse()
                    }
                } else if request.method == "POST",
                          request.path == MirrorTransport.activityTokenPath {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    if let registration = try? decoder.decode(ActivityPushRegistration.self, from: request.body) {
                        activityTokens.call(registration)
                        response = MirrorTransport.jsonResponse(Data(#"{"ok":true}"#.utf8))
                        onServed(request)
                    } else {
                        response = MirrorTransport.badRequestResponse()
                    }
                } else {
                    response = MirrorTransport.notFoundResponse()
                }
                connection.send(content: response,
                                completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            // Nothing to answer yet — and nothing ever will be if the peer
            // hung up or is spraying bytes without a request line. Allow a
            // little headroom over the cap for the head itself.
            guard error == nil, !isComplete, buffer.count < cap + 4096 else {
                connection.cancel()
                return
            }
            receive(connection, buffer: buffer, payload: payload, token: token,
                   sessionFeed: sessionFeed, sessionInput: sessionInput, sessionImage: sessionImage,
                   activityTokens: activityTokens, crashes: crashes, awsLogin: awsLogin, onServed: onServed)
        }
    }
}
