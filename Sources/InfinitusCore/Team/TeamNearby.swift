import Foundation

/// The team side of Nearby (spec §6.4): what this machine advertises,
/// the two LAN routes (`GET /team/key`, `POST /team/request`) as pure
/// request → response functions so the Mac's MirrorServer and the
/// Linux PosixHTTPServer mount one handler, and where an incoming
/// request lands. `POST /team/invite` is step 6's. Lives beside
/// TeamClient, never in it: TeamClient's surface is the publisher's.
public enum TeamNearby {
    public static let keyPath = "/team/key"
    public static let requestPath = "/team/request"
    public static let routePrefix = "/team/"
    /// The UserDefaults bool the Mac app, its Team pane (plan 5) and
    /// `infinitusctl team-discoverable` share. Off by default.
    public static let discoverableDefaultsKey = "team_discoverable"
    /// Pending requests kept per team: the LAN route needs no token, so
    /// its footprint on disk is bounded.
    public static let pendingCap = 100

    /// `GET /team/key`.
    public struct KeyReply: Codable, Equatable, Sendable {
        public var name: String
        public var keys: TeamKeys
        public var team: String?
        public var role: String

        public init(name: String, keys: TeamKeys, team: String?, role: String) {
            self.name = name; self.keys = keys; self.team = team; self.role = role
        }
    }

    /// `POST /team/request` body. `TeamRequest` names no team (a leader
    /// may lead several), so the LAN body says which one.
    public struct Request: Codable, Equatable, Sendable {
        public var team: String
        public var request: Signed<TeamRequest>

        public init(team: String, request: Signed<TeamRequest>) {
            self.team = team; self.request = request
        }
    }

    public struct RequestReply: Codable, Equatable, Sendable {
        public var ok: Bool
        /// "branch": the team's requests branch took it (the leader's
        /// `requests()` sees it); "pending": kept locally until it can.
        public var stored: String

        public init(ok: Bool, stored: String) { self.ok = ok; self.stored = stored }
    }

    // MARK: local standing

    public struct Local: Equatable, Sendable {
        public var record: NearbyRecord
        /// nil while hidden: no identity is minted for a machine that
        /// isn't advertising.
        public var keys: TeamKeys?
        /// False only when this machine leads the advertised team and
        /// that team's roster has closed requests (`policy.requests ==
        /// "off"`, spec §6.3/§6.4): `POST /team/request` must be refused
        /// before anything is written. True whenever there's no team to
        /// close, or this machine is a member rather than the leader.
        public var requestsOpen: Bool

        public init(record: NearbyRecord, keys: TeamKeys?, requestsOpen: Bool = true) {
            self.record = record; self.keys = keys; self.requestsOpen = requestsOpen
        }

        public static let hidden = Local(record: .hidden, keys: nil)

        /// Leader of any team → leader of the first (sorted) such team;
        /// else member likewise; else none. Opens the team clones (file
        /// IO, no network on an existing mirror) — the app calls this off
        /// the main actor.
        public static func load(name: String, discoverable: Bool, paths: TeamPaths, secrets: TeamSecrets) -> Local {
            guard discoverable, let me = try? TeamClient.identity(paths: paths, secrets: secrets) else { return .hidden }
            var team: String? = nil
            var role = "none"
            var requestsOpen = true
            for id in paths.teamIDs() {
                guard let client = try? TeamClient.open(id: id, paths: paths, secrets: secrets) else { continue }
                if client.isLeader {
                    team = id; role = "leader"
                    requestsOpen = client.roster?.doc.policy.requests != "off"
                    break
                }
                if client.isMember, role == "none" { team = id; role = "member" }
            }
            return Local(record: NearbyRecord(name: name, kid: me.kid, team: team, role: role, discoverable: true),
                         keys: me.keys, requestsOpen: requestsOpen)
        }
    }

    // MARK: routes

    /// What the routes need: the local standing and where a request goes
    /// (`store` returns "branch" or "pending").
    public struct Endpoint {
        public var local: Local
        public var store: (Request) throws -> String

        public init(local: Local, store: @escaping (Request) throws -> String) {
            self.local = local; self.store = store
        }
    }

    /// nil = not a `/team/` route, keep routing. A hidden (or absent)
    /// endpoint answers 404 to every team route — the spec's "off ⇒ the
    /// endpoints answer 404". No pairing token here: peers have none.
    public static func respond(_ request: MirrorTransport.Request, endpoint: Endpoint?) -> Data? {
        guard request.path.hasPrefix(routePrefix) else { return nil }
        guard let endpoint, endpoint.local.record.discoverable, let keys = endpoint.local.keys else {
            return MirrorTransport.notFoundResponse()
        }
        switch (request.method, request.path) {
        case ("GET", TeamNearby.keyPath):
            let reply = KeyReply(name: endpoint.local.record.name, keys: keys,
                                 team: endpoint.local.record.team, role: endpoint.local.record.role)
            guard let body = try? CanonicalJSON.encode(reply) else { return MirrorTransport.notFoundResponse() }
            return MirrorTransport.jsonResponse(body)
        case ("POST", TeamNearby.requestPath):
            guard let incoming = try? CanonicalJSON.decode(Request.self, from: request.body),
                  (try? incoming.request.verify(with: incoming.request.doc.keys)) != nil else {
                return MirrorTransport.badRequestResponse()
            }
            guard incoming.team == endpoint.local.record.team else { return MirrorTransport.notFoundResponse() }
            // Stream ruling: policy.requests == "off" refuses outright,
            // no storage at all — checked before the store is ever
            // called, not inside it.
            guard endpoint.local.requestsOpen else {
                return MirrorTransport.response(status: 403, reason: "Forbidden", contentType: "text/plain",
                                                body: Data("requests closed\n".utf8))
            }
            do {
                let stored = try endpoint.store(incoming)
                guard let body = try? CanonicalJSON.encode(RequestReply(ok: true, stored: stored)) else {
                    return MirrorTransport.notFoundResponse()
                }
                return MirrorTransport.jsonResponse(body)
            } catch {
                return MirrorTransport.response(status: 503, reason: "Service Unavailable", contentType: "text/plain",
                                                body: Data("request not stored\n".utf8))
            }
        default:
            return MirrorTransport.notFoundResponse()
        }
    }

    // MARK: storage

    public enum StoreError: Error, Equatable { case unknownTeam, badKid, full }

    public enum Store {
        public static func pendingDir(team: String, paths: TeamPaths) -> URL {
            paths.teamDir(team).appendingPathComponent("pending")
        }

        /// A kid names one file, so it is one path segment.
        static func isPathSegment(_ kid: String) -> Bool {
            !kid.isEmpty && !kid.contains("/") && kid != "." && kid != ".."
        }

        /// Keeps the request under `<team>/pending/<kid>.json`, then tries
        /// the team's `requests` branch; on success the pending copy goes
        /// (the leader's `requests()` sees it there). "branch" | "pending".
        public static func save(_ incoming: Request, paths: TeamPaths, secrets: TeamSecrets) throws -> String {
            let kid = incoming.request.doc.keys.kid
            guard isPathSegment(kid) else { throw StoreError.badKid }
            guard paths.teamIDs().contains(incoming.team) else { throw StoreError.unknownTeam }
            let dir = pendingDir(team: incoming.team, paths: paths)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("\(kid).json")
            let existing = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            guard existing.count < TeamNearby.pendingCap || FileManager.default.fileExists(atPath: file.path) else {
                throw StoreError.full
            }
            try CanonicalJSON.encode(incoming.request).write(to: file)
            do {
                try writeToRequestsBranch(team: incoming.team, signed: incoming.request, paths: paths, secrets: secrets)
            } catch {
                return "pending"
            }
            try? FileManager.default.removeItem(at: file)
            return "branch"
        }

        /// Requests that never reached the branch, by kid; unreadable or
        /// unverifiable files are skipped.
        public static func pending(team: String, paths: TeamPaths) -> [Signed<TeamRequest>] {
            let dir = pendingDir(team: team, paths: paths)
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
            return names.compactMap { name in
                guard name.hasSuffix(".json"),
                      let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                      let signed = try? CanonicalJSON.decode(Signed<TeamRequest>.self, from: data),
                      (try? signed.verify(with: signed.doc.keys)) != nil else { return nil }
                return signed
            }
        }

        /// `requests/<kid>.json` on the team's store, with whatever
        /// credential this machine holds: the leader's when a request
        /// arrives over the LAN, the joiner's own when it already has the
        /// code. TeamClient keeps its store private, so this opens the
        /// same bare mirror TeamClient uses (`paths.storeDir`).
        public static func writeToRequestsBranch(team: String, signed: Signed<TeamRequest>,
                                                 paths: TeamPaths, secrets: TeamSecrets) throws {
            let kid = signed.doc.keys.kid
            guard isPathSegment(kid) else { throw StoreError.badKid }
            let config = try CanonicalJSON.decode(TeamConfig.self, from: try Data(contentsOf: paths.configFile(team)))
            let token = secrets.read(TeamClient.tokenName(team)).map { String(decoding: $0, as: UTF8.self) }
            let store = TeamGit(dir: paths.storeDir(team), remote: config.remote, token: token, author: config.kid)
            try store.open()
            try store.put("requests/\(kid).json", try CanonicalJSON.encode(signed))
        }
    }
}
