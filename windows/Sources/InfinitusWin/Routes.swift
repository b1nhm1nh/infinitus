import Foundation
import InfinitusCore

/// W7: the phone-facing HTTP surface. Every route answers exactly what
/// the Mac's tray answers (`Sources/InfinitusTray/InfinitusTray.swift`),
/// so the phone can't tell a Windows host from a Mac one except by what
/// the snapshot declares.
///
/// Input tries an owned child first (stdin), then the named pipe.
/// `hosts: []` keeps `SessionInput.deliver`'s terminal fallback out of
/// reach, because Windows Terminal has no send-keys. A `key` press on a
/// session nobody owns therefore reports `noSurface` rather than
/// pretending.
enum Routes {
    /// Builds the one handler `WinHTTPServer` mounts.
    ///
    /// `locate` / `startOverride` / `deliverOverride` are test seams: the
    /// daemon passes the box and lets the defaults call `ClaudeLocator`
    /// and the actor. Tests inject so this file never spawns a child.
    static func handler(claudeDir: URL, snapshot: SnapshotCache,
                        token: String,
                        owned: OwnedSessionsBox,
                        locate: @escaping @Sendable () -> String? = { ClaudeLocator.locate() },
                        startOverride: (@Sendable (SessionStart.Request) -> SessionStart.Reply)? = nil,
                        deliverOverride: (@Sendable (SessionInput.Request, ClaudeSessionRecord) -> SessionInput.Reply?)? = nil,
                        log: @escaping @Sendable (String) -> Void = { _ in })
        -> @Sendable (MirrorTransport.Request) -> Data {
        { request in
            guard MirrorTransport.isAuthorized(request, token: token) else {
                return MirrorTransport.unauthorizedResponse()
            }
            if request.method == "GET", request.path == MirrorTransport.snapshotPath {
                let data = snapshot.data()
                return data.isEmpty ? MirrorTransport.unavailableResponse()
                                    : MirrorTransport.snapshotResponse(data)
            }
            if request.method == "GET", let pid = MirrorTransport.sessionTailPid(request.path) {
                return tail(pid: pid, request: request, claudeDir: claudeDir, owned: owned)
            }
            if request.method == "GET", let ref = MirrorTransport.sessionImageRef(request.path) {
                return image(pid: ref.pid, id: ref.id, claudeDir: claudeDir)
            }
            if request.method == "POST", let pid = MirrorTransport.sessionInputPid(request.path) {
                return input(pid: pid, request: request, claudeDir: claudeDir,
                             owned: owned, deliverOverride: deliverOverride, log: log)
            }
            if request.method == "POST", request.path == SessionStart.path {
                return start(request: request, owned: owned, locate: locate,
                             startOverride: startOverride, log: log)
            }
            // The phone posts its push token on launch. Windows cannot push
            // to APNs directly: Apple requires a .p8 private signing key
            // held exclusively in macOS Keychain, and LiveActivityPush has no
            // non-CryptoKit ES256 signing path.
            // Mac-relay option (Option B in docs/windows-phase-04-push.md) was
            // considered but rejected for v1: it re-introduces a 24/7 Mac
            // relay dependency and opens an inbound push trust surface.
            // Option A: accept 2xx with an explicit capability flag so the phone
            // knows lock-screen push delivery is unavailable on this host.
            if request.method == "POST", request.path == MirrorTransport.activityTokenPath {
                return MirrorTransport.jsonResponse(
                    Data(#"{"ok":true,"canPush":false,"pushCapable":false,"reason":"APNs requires Apple .p8 key held only in macOS keychain"}"#.utf8))
            }
            return MirrorTransport.notFoundResponse()
        }
    }

    /// `GET /sessions/<pid>/tail?n=&since=&wait=` — the session's feed,
    /// long-polling when `since`/`wait` are given. Blocking is fine: the
    /// listener runs one thread per connection.
    static func tail(pid: Int32, request: MirrorTransport.Request, claudeDir: URL,
                     owned: OwnedSessionsBox) -> Data {
        let limit = max(0, request.query(MirrorTransport.tailLimitQueryName).flatMap(Int.init) ?? 30)
        SessionFeedReader.waitForChange(
            pid: pid, claudeDir: claudeDir,
            since: request.query(MirrorTransport.tailSinceQueryName),
            wait: request.query(MirrorTransport.tailWaitQueryName).flatMap(Double.init) ?? 0)
        guard let record = ClaudeSessions.list(claudeDir: claudeDir).first(where: { $0.pid == pid }),
              let feed = SessionFeedReader.read(record: record, claudeDir: claudeDir, limit: limit)
        else {
            return MirrorTransport.notFoundResponse()
        }
        // W9: the phone gates its composer on these. `keys` is false —
        // Windows Terminal exposes no send-keys — so a session whose pipe
        // is gone is honestly uncontrollable rather than silently ignored.
        // Owned children have no peer pipe but ARE deliverable (stdin), so
        // they still get canMessage — otherwise the phone hides the composer.
        let canMessage = owned.existing?.ownedPids.contains(pid) == true
            || NamedPipe.isListening(record.messagingSocketPath)
        let annotated = SessionFeed(
            pid: feed.pid, sessionId: feed.sessionId, cwd: feed.cwd, status: feed.status,
            waiting: feed.waiting, items: feed.items, name: feed.name, stamp: feed.stamp,
            canMessage: canMessage, keys: false,
            permissionMode: feed.permissionMode)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let encoded = try? encoder.encode(annotated) else {
            return MirrorTransport.notFoundResponse()
        }
        return MirrorTransport.snapshotResponse(encoded)
    }

    /// `GET /sessions/<pid>/images/<id>` — original bytes with the
    /// transcript's media type (WIC downscaling is W16), capped so a
    /// pathological transcript can't hand the phone a 100 MB body.
    static func image(pid: Int32, id: String, claudeDir: URL) -> Data {
        guard let record = ClaudeSessions.list(claudeDir: claudeDir).first(where: { $0.pid == pid }),
              let found = SessionFeedReader.imageData(
                  record: record, id: id, claudeDir: claudeDir,
                  attachmentsDir: SessionInput.defaultAttachmentsDir),
              found.data.count <= maxImageBytes
        else {
            return MirrorTransport.notFoundResponse()
        }
        return MirrorTransport.imageResponse(found.data, contentType: found.mime)
    }

    /// A pasted screenshot is ~200 KB; a phone attachment is capped at
    /// `SessionInput.maxAttachmentBytes`. 5 MiB covers both.
    static let maxImageBytes = 5 * 1024 * 1024

    /// `POST /sessions/<pid>/input` — a message, a resume, or a key.
    /// Owned children get stdin (`OwnedSessions.deliver` is nil for a pid
    /// we don't own — that nil is the fallthrough signal); everyone else
    /// the named pipe. `existing` is the lookup: a miss must not locate
    /// `claude`.
    static func input(pid: Int32, request: MirrorTransport.Request, claudeDir: URL,
                      owned: OwnedSessionsBox,
                      deliverOverride: (@Sendable (SessionInput.Request, ClaudeSessionRecord) -> SessionInput.Reply?)?,
                      log: @escaping @Sendable (String) -> Void) -> Data {
        guard let decoded = try? JSONDecoder().decode(SessionInput.Request.self, from: request.body)
        else {
            return MirrorTransport.badRequestResponse()
        }
        guard let record = ClaudeSessions.list(claudeDir: claudeDir).first(where: { $0.pid == pid })
        else {
            log("phone input not delivered: unknown session \(pid)")
            return MirrorTransport.notFoundResponse()
        }
        let deliver = deliverOverride ?? owned.existing?.deliver
        let reply = SessionInput.deliver(
            request: decoded, record: record,
            hosts: [],                       // no pty on Windows: owned stdin or pipe
            claudeDir: claudeDir,
            ttyOfPid: { _ in nil }, ancestorsOf: { _ in [] },
            socketSend: { record, text in
                NamedPipe.send(text: text, record: record, claudeDir: claudeDir)
            },
            owned: deliver)
        let label = URL(fileURLWithPath: record.cwd).lastPathComponent
        if reply.outcome == "delivered" {
            log("phone -> \(label): \"\(decoded.text.prefix(60))\" (\(reply.channel ?? "?"))")
        } else {
            log("phone input not delivered to \(label): \(reply.outcome)")
        }
        return json(reply)
    }

    /// `POST /sessions/start` — spawn a headless `claude` this daemon owns
    /// over stdin/stdout. Windows has no terminal host, so `headless: false`
    /// is `noHost` rather than pretending.
    static func start(request: MirrorTransport.Request,
                      owned: OwnedSessionsBox,
                      locate: @escaping @Sendable () -> String?,
                      startOverride: (@Sendable (SessionStart.Request) -> SessionStart.Reply)?,
                      log: @escaping @Sendable (String) -> Void) -> Data {
        guard let decoded = try? JSONDecoder().decode(SessionStart.Request.self, from: request.body)
        else {
            return MirrorTransport.badRequestResponse()
        }
        if decoded.headless == false {
            return json(SessionStart.Reply(outcome: "noHost",
                                           detail: "Windows has no terminal host"))
        }
        // Tests inject a reply so this file never spawns a child. Live
        // traffic falls through to locate + the actor.
        if let startOverride { return json(startOverride(decoded)) }
        // Locating claude may run a login shell. Fine here: WinHTTPServer
        // is one thread per connection, so this never holds the accept loop
        // (the Mac hops off its connection queue for the same wait).
        guard let sessions = owned.get(make: {
            guard let path = locate() else { return nil }
            return OwnedSessions(binaryPath: path) { pid, state in
                switch state {
                case .exited: log("headless session \(pid) ended")
                case .waiting: log("headless session \(pid) is waiting for an answer")
                default: break
                }
            }
        }) else {
            let need = ClaudeLocator.minimumVersion.map(String.init).joined(separator: ".")
            return json(SessionStart.Reply(
                outcome: "failed",
                detail: "claude isn't on PATH; a headless session needs Claude Code \(need) or newer"))
        }
        let reply = waitStart(sessions, decoded)
        if reply.outcome == "started" {
            let label = URL(fileURLWithPath: decoded.cwd).lastPathComponent
            log("phone started a session in \(label): started via owned")
        }
        return json(reply)
    }

    /// Awaits the actor on this connection thread. Safe: the listener
    /// never shares the thread with accept or another request.
    static func waitStart(_ owned: OwnedSessions, _ request: SessionStart.Request) -> SessionStart.Reply {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var reply = SessionStart.Reply(outcome: "failed", detail: "start did not complete")
        Task { reply = await owned.start(request); done.signal() }
        done.wait()
        return reply
    }

    static func json<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)).map(MirrorTransport.jsonResponse)
            ?? MirrorTransport.notFoundResponse()
    }
}
