import Foundation

/// Local plaintext state for one team (no secrets: the token is in
/// `TeamSecrets` under `team.<id>.token`).
public struct TeamConfig: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var remote: String
    public var kid: String
    public var joinedAt: Int
    /// The leader whose signature the code carried: the root of trust for
    /// the first roster this client accepts.
    public var leaderKid: String
}

public struct TeamStatus: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var remote: String
    public var kid: String
    /// "leader" | "member" | "pending"
    public var role: String
    public var rev: Int?
    public var leaders: Int
    public var members: Int
    public var requests: Int
}

/// One machine's view of one team (spec §6, §7 minimal, §8.1 minimal):
/// composes identity, store, roster and envelopes. Synchronous; the app
/// calls it off the main thread.
public final class TeamClient {
    public enum ClientError: Error, Equatable {
        case notALeader, notInTeam, noRoster, unknownRequest, badCode, alreadyJoined
        /// The kid is already a leader of this roster.
        case alreadyLeader
        /// The kid is already a member under different keys.
        case keyMismatch
        /// Another leader kept winning the roster push race.
        case rosterConflict
        /// The kid is neither a leader nor a member.
        case unknownMember
        /// The founding leader cannot be removed (spec §1 co-leader rule).
        case founder
        /// A team keeps at least one leader.
        case lastLeader
        /// `policy.requests == "off"`: no new codes, no request list.
        case requestsOff
    }

    public static let identitySecretName = "identity"
    public static func tokenName(_ id: String) -> String { "team.\(id).token" }

    public let config: TeamConfig
    public let identity: TeamIdentity
    public private(set) var roster: Signed<TeamRoster>?
    private let paths: TeamPaths
    /// Test hook: where the client's own files (state, caches) live.
    var teamDirForTests: URL { paths.teamDir(config.id) }
    private let secrets: TeamSecrets
    let store: TeamGit

    public var isLeader: Bool { roster?.doc.isLeader(identity.kid) ?? false }
    public var isMember: Bool { roster?.doc.keys(for: identity.kid) != nil }

    // MARK: identity

    public static func identity(paths: TeamPaths, secrets: TeamSecrets) throws -> TeamIdentity {
        if let secret = secrets.read(identitySecretName), secret.count == 32 {
            return try TeamIdentity(secret: secret)
        }
        let fresh = TeamIdentity.random()
        try secrets.write(identitySecretName, fresh.secret)
        return fresh
    }

    // MARK: construction

    private init(config: TeamConfig, identity: TeamIdentity, roster: Signed<TeamRoster>?,
                 paths: TeamPaths, secrets: TeamSecrets, store: TeamGit) {
        self.config = config; self.identity = identity; self.roster = roster
        self.paths = paths; self.secrets = secrets; self.store = store
    }

    public static func create(name: String, remote: String, token: String?, leaderName: String = "Leader",
                              paths: TeamPaths, secrets: TeamSecrets,
                              now: Int = Int(Date().timeIntervalSince1970)) throws -> TeamClient {
        let me = try identity(paths: paths, secrets: secrets)
        let id = UUID().uuidString.lowercased()
        let config = TeamConfig(id: id, name: name, remote: remote, kid: me.kid, joinedAt: now, leaderKid: me.kid)
        if let token { try secrets.write(tokenName(id), Data(token.utf8)) }
        let store = TeamGit(dir: paths.storeDir(id), remote: remote, token: token, author: me.kid)
        try store.open()
        let roster = TeamRoster(id: id, name: name, createdAt: now,
                                leaders: [TeamRoster.Member(keys: me.keys, name: leaderName, since: now, founder: true)],
                                rev: 1)
        let signed = try Signed.make(roster, by: me)
        try store.put("roster/team.json", try CanonicalJSON.encode(signed))
        let client = TeamClient(config: config, identity: me, roster: signed, paths: paths, secrets: secrets, store: store)
        try client.persist()
        return client
    }

    public static func request(code text: String, name: String, devices: [String], platform: String,
                               paths: TeamPaths, secrets: TeamSecrets,
                               now: Int = Int(Date().timeIntervalSince1970)) throws -> TeamClient {
        let code = try TeamCode.decode(text, now: now)
        guard !paths.teamIDs().contains(code.team) else { throw ClientError.alreadyJoined }
        let me = try identity(paths: paths, secrets: secrets)
        let config = TeamConfig(id: code.team, name: code.name, remote: code.remote, kid: me.kid,
                                joinedAt: now, leaderKid: code.leader.kid)
        if let token = code.token { try secrets.write(tokenName(code.team), Data(token.utf8)) }
        let store = TeamGit(dir: paths.storeDir(code.team), remote: code.remote, token: code.token, author: me.kid)
        try store.open()
        let client = TeamClient(config: config, identity: me, roster: nil, paths: paths, secrets: secrets, store: store)
        // The roster must be led by the leader the code named, or the code
        // points at someone else's store: any roster-acceptance failure on
        // this first fetch is the code's fault, not the store's.
        do { _ = try client.fetch() } catch is TeamRoster.RosterError { throw ClientError.badCode }
        let request = TeamRequest(keys: me.keys, name: name, devices: devices, platform: platform, at: now, nonce: code.nonce)
        try store.put("requests/\(me.kid).json", try CanonicalJSON.encode(try Signed.make(request, by: me)))
        try client.persist()
        return client
    }

    public static func open(id: String, paths: TeamPaths, secrets: TeamSecrets) throws -> TeamClient {
        let config = try CanonicalJSON.decode(TeamConfig.self, from: try Data(contentsOf: paths.configFile(id)))
        let me = try identity(paths: paths, secrets: secrets)
        let token = secrets.read(tokenName(id)).map { String(decoding: $0, as: UTF8.self) }
        let store = TeamGit(dir: paths.storeDir(id), remote: config.remote, token: token, author: me.kid)
        let roster = (try? Data(contentsOf: paths.rosterFile(id)))
            .flatMap { try? CanonicalJSON.decode(Signed<TeamRoster>.self, from: $0) }
        let client = TeamClient(config: config, identity: me, roster: roster, paths: paths, secrets: secrets, store: store)
        try store.open()
        return client
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: paths.teamDir(config.id), withIntermediateDirectories: true)
        try CanonicalJSON.encode(config).write(to: paths.configFile(config.id))
        if let roster { try CanonicalJSON.encode(roster).write(to: paths.rosterFile(config.id)) }
    }

    // MARK: roster

    /// Pulls the remote and accepts its roster if the rules allow; a bad
    /// roster throws and the last accepted one stays.
    @discardableResult
    public func fetch() throws -> TeamRoster {
        try store.sync()
        guard let data = try store.get("roster/team.json") else { throw ClientError.noRoster }
        let candidate = try CanonicalJSON.decode(Signed<TeamRoster>.self, from: data)
        if let roster {
            if candidate != roster {
                try TeamRoster.Acceptance.check(candidate, previous: roster)
                self.roster = candidate
            }
        } else {
            // First roster: it must be this team's, and the leader the code
            // named must have SIGNED it — listing them is not enough, since
            // every code holder can write to the store.
            guard candidate.doc.id == config.id else { throw TeamRoster.RosterError.differentTeam }
            try TeamRoster.Acceptance.check(candidate, previous: nil, trustRoot: config.leaderKid)
            self.roster = candidate
        }
        try persist()
        // Non-nil on both branches; the previous roster stands if the
        // candidate was identical.
        return self.roster?.doc ?? candidate.doc
    }

    /// The roster is computed from the roster we read, so a lost push
    /// race must never be retried with the same bytes: it would discard
    /// the other leader's edit. Callers recompute (see `approve`).
    private func saveRoster(_ roster: TeamRoster) throws {
        let signed = try Signed.make(roster, by: identity)
        try store.putAll(["roster/team.json": try CanonicalJSON.encode(signed)], retryOnRace: false)
        self.roster = signed
        try persist()
    }

    public func code(expiresIn seconds: Int = 7 * 86_400, nonce: String? = nil,
                     now: Int = Int(Date().timeIntervalSince1970)) throws -> String {
        guard isLeader else { throw ClientError.notALeader }
        guard roster?.doc.policy.requests != "off" else { throw ClientError.requestsOff }
        let token = secrets.read(Self.tokenName(config.id)).map { String(decoding: $0, as: UTF8.self) }
        return try TeamCode(team: config.id, name: config.name, remote: config.remote, token: token,
                            leader: identity.keys, expires: now + seconds, nonce: nonce).encoded(by: identity)
    }

    public func requests() throws -> [Signed<TeamRequest>] {
        guard isLeader else { throw ClientError.notALeader }
        if roster?.doc.policy.requests == "off" { return [] }
        return try store.list("requests/").compactMap { entry in
            guard let data = try store.get(entry.path),
                  let signed = try? CanonicalJSON.decode(Signed<TeamRequest>.self, from: data),
                  (try? signed.verify(with: signed.doc.keys)) != nil,
                  entry.path == "requests/\(signed.doc.keys.kid).json" else { return nil }
            return signed
        }
    }

    /// A kid names one file under `requests/`, so it is one path segment.
    private static func isPathSegment(_ kid: String) -> Bool {
        !kid.isEmpty && !kid.contains("/") && kid != "." && kid != ".."
    }

    public func approve(kid: String, now: Int = Int(Date().timeIntervalSince1970)) throws {
        guard Self.isPathSegment(kid) else { throw ClientError.unknownRequest }
        // Another leader may push a roster between our read and our push;
        // recompute on theirs rather than overwrite it.
        for _ in 0..<3 {
            guard let current = roster?.doc else { throw ClientError.noRoster }
            guard isLeader else { throw ClientError.notALeader }
            // Approving a leader would append a second entry under their kid.
            guard !current.isLeader(kid) else { throw ClientError.alreadyLeader }
            guard let request = try requests().first(where: { $0.doc.keys.kid == kid }) else { throw ClientError.unknownRequest }
            // Re-approving the same keys is fine; different keys under a kid
            // this roster already knows would silently replace a member.
            if let known = current.keys(for: kid), known != request.doc.keys { throw ClientError.keyMismatch }
            var next = current
            next.members.removeAll { $0.keys.kid == kid }
            next.removed.removeAll { $0.kid == kid }
            next.members.append(TeamRoster.Member(keys: request.doc.keys, name: request.doc.name, since: now,
                                                  devices: request.doc.devices))
            next.rev += 1
            do {
                try saveRoster(next)
            } catch TeamGit.GitError.raceLost {
                _ = try fetch()
                continue
            }
            try store.delete("requests/\(kid).json")
            return
        }
        throw ClientError.rosterConflict
    }

    public func decline(kid: String) throws {
        guard isLeader else { throw ClientError.notALeader }
        guard Self.isPathSegment(kid) else { throw ClientError.unknownRequest }
        let path = "requests/\(kid).json"
        guard try store.get(path) != nil else { throw ClientError.unknownRequest }
        try store.delete(path)
    }

    /// One roster edit with the same race loop as `approve`: recompute
    /// on the other leader's roster rather than overwrite it.
    private func editRoster(_ edit: (TeamRoster) throws -> TeamRoster) throws {
        for _ in 0..<3 {
            guard let current = roster?.doc else { throw ClientError.noRoster }
            guard isLeader else { throw ClientError.notALeader }
            var next = try edit(current)
            next.rev = current.rev + 1
            do {
                try saveRoster(next)
                return
            } catch TeamGit.GitError.raceLost {
                _ = try fetch()
                continue
            }
        }
        throw ClientError.rosterConflict
    }

    /// Spec §6.5: the kid moves to `removed` with its keys and the
    /// removal instant; envelopes it sealed before `now` stay readable,
    /// later ones are ignored, and its next `fetch` ends its membership.
    public func remove(kid: String, now: Int = Int(Date().timeIntervalSince1970)) throws {
        try editRoster { current in
            guard let keys = current.keys(for: kid) else { throw ClientError.unknownMember }
            if let target = current.leaders.first(where: { $0.keys.kid == kid }) {
                guard !target.founder else { throw ClientError.founder }
                guard current.leaders.count > 1 else { throw ClientError.lastLeader }
            }
            var next = current
            next.leaders.removeAll { $0.keys.kid == kid }
            next.members.removeAll { $0.keys.kid == kid }
            next.removed.removeAll { $0.kid == kid }
            next.removed.append(TeamRoster.Removed(kid: kid, at: now, keys: keys))
            return next
        }
    }

    /// Spec §6.5: a member becomes a (non-founder) leader; its key is a
    /// `.leaders` recipient from now on. Re-wrapping history is the
    /// member's choice (`TeamPublisher.reshare`).
    public func promote(kid: String, now: Int = Int(Date().timeIntervalSince1970)) throws {
        try editRoster { current in
            guard !current.isLeader(kid) else { throw ClientError.alreadyLeader }
            guard let member = current.members.first(where: { $0.keys.kid == kid }) else { throw ClientError.unknownMember }
            var next = current
            next.members.removeAll { $0.keys.kid == kid }
            next.leaders.append(member)
            return next
        }
    }

    // MARK: files

    public struct PublishItem: Equatable {
        public var kind: String
        public var path: String
        public var plaintext: Data
        public var audience: TeamRoster.ShareTarget
        public init(kind: String, path: String, plaintext: Data, audience: TeamRoster.ShareTarget) {
            self.kind = kind; self.path = path; self.plaintext = plaintext; self.audience = audience
        }
    }

    /// Seals every item to its audience and pushes them under
    /// `m/<my kid>/` as ONE commit (a publish is five-plus files). Each
    /// path's shape must name the item's kind (`TeamKinds`), or readers
    /// would drop it. Returns the store paths in item order.
    @discardableResult
    public func publish(_ items: [PublishItem], now: Int = Int(Date().timeIntervalSince1970)) throws -> [String] {
        guard let roster = roster?.doc, isMember else { throw ClientError.notInTeam }
        var writes: [String: Data?] = [:]
        var paths: [String] = []
        for item in items {
            let storePath = "m/\(identity.kid)/\(item.path)"
            try TeamKinds.check(kind: item.kind, from: identity.kid, at: storePath)
            writes[storePath] = try Envelope.seal(item.plaintext, kind: item.kind, from: identity,
                                                  to: roster.recipients(for: item.audience), at: now)
            paths.append(storePath)
        }
        if !writes.isEmpty { try store.putAll(writes) }
        return paths
    }

    /// One file; see `publish(_:now:)`.
    @discardableResult
    public func publish(kind: String, path: String, plaintext: Data, audience: TeamRoster.ShareTarget,
                        now: Int = Int(Date().timeIntervalSince1970)) throws -> String {
        try publish([PublishItem(kind: kind, path: path, plaintext: plaintext, audience: audience)], now: now)[0]
    }

    /// Deletes `m/<my kid>/<path>` (spec §7: `now.json` goes on quit).
    public func unpublish(path: String) throws {
        guard isMember else { throw ClientError.notInTeam }
        try store.delete("m/\(identity.kid)/\(path)")
    }

    /// Spec §6.5 leave: every file under `m/<my kid>/` is deleted (the
    /// history stays, ciphertext) and `requests/<kid>.leave` tells the
    /// leaders — one push. The caller then forgets the team locally
    /// (team dir + token secret); the identity stays.
    public func leave(now: Int = Int(Date().timeIntervalSince1970)) throws {
        try store.sync()  // list() reads local refs only; a stale tree leaves another device's files behind
        var writes: [String: Data?] = [:]
        for entry in try store.list("m/") where entry.path.hasPrefix("m/\(identity.kid)/") {
            // A plain `writes[entry.path] = nil` subscript-assign on a
            // `[String: Data?]` collapses the double optional and REMOVES
            // the key instead of staging a delete — `updateValue` is the
            // one that keeps the key with a nil payload.
            writes.updateValue(nil, forKey: entry.path)
        }
        let note = TeamRequest(keys: identity.keys, name: "", devices: [], platform: "leave", at: now)
        writes["requests/\(identity.kid).leave"] = try CanonicalJSON.encode(try Signed.make(note, by: identity))
        try store.putAll(writes)
    }

    /// Envelopes under `m/` that name me as a reader, sit at a path whose
    /// shape matches their kind and sender, and come from someone who
    /// was in the roster when they were sealed. Reads headers only.
    public func readableHeaders() throws -> [(entry: StoreEntry, header: Envelope.Header)] {
        guard let roster = roster?.doc else { return [] }
        // Headers are remembered per (path, blob version) so a loop pass
        // reads only files that changed; the roster / kind / recipient
        // checks still run every time, since the roster moves.
        let cacheURL = paths.teamDir(config.id).appendingPathComponent("headers.json")
        var cache = HeaderCache.load(cacheURL)
        var kept: [String: HeaderCache.Entry] = [:]
        var out: [(entry: StoreEntry, header: Envelope.Header)] = []
        for entry in try store.list("m/") + (try store.list("roster/aggregates/")) {
            let header: Envelope.Header
            if let cached = cache.entries[entry.path], cached.version == entry.version {
                header = cached.header
            } else {
                guard let data = try store.get(entry.path), let parsed = try? Envelope.header(of: data) else { continue }
                header = parsed
            }
            kept[entry.path] = HeaderCache.Entry(version: entry.version, header: header)
            guard (try? TeamKinds.check(header, at: entry.path)) != nil,
                  roster.keys(for: header.from, at: header.at) != nil,
                  header.to.contains(where: { $0.kid == identity.kid }) else { continue }
            out.append((entry, header))
        }
        if kept != cache.entries { cache.entries = kept; try? cache.save(cacheURL) }
        return out
    }

    /// `<team dir>/headers.json`: envelope headers by store path and blob version.
    struct HeaderCache: Codable, Equatable {
        struct Entry: Codable, Equatable { var version: String; var header: Envelope.Header }
        var entries: [String: Entry] = [:]
        static func load(_ url: URL) -> HeaderCache {
            (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(HeaderCache.self, from: $0) } ?? HeaderCache()
        }
        func save(_ url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(self).write(to: url)
        }
    }

    public func readable() throws -> [StoreEntry] { try readableHeaders().map(\.entry) }

    public func read(_ path: String) throws -> (Envelope.Header, Data) {
        guard let roster = roster?.doc else { throw ClientError.noRoster }
        guard let data = try store.get(path) else { throw Envelope.EnvelopeError.malformed }
        let header = try Envelope.header(of: data)
        try TeamKinds.check(header, at: path)
        return try Envelope.open(data, as: identity, senderKey: { roster.keys(for: $0, at: header.at) })
    }

    // MARK: aggregates (spec §8.3, plan 9)

    /// Leaders publish `roster/aggregates/<period>.json` to the whole team,
    /// one commit. Readers keep only what a leader sealed (TeamReader).
    @discardableResult
    public func publishAggregates(_ docs: [String: Data], now: Int = Int(Date().timeIntervalSince1970)) throws -> [String] {
        guard let roster = roster?.doc, isLeader else { throw ClientError.notALeader }
        var writes: [String: Data?] = [:]
        var paths: [String] = []
        for (period, plaintext) in docs.sorted(by: { $0.key < $1.key }) {
            let path = "roster/aggregates/\(period).json"
            try TeamKinds.check(kind: TeamKinds.aggregates, from: identity.kid, at: path)
            writes[path] = try Envelope.seal(plaintext, kind: TeamKinds.aggregates, from: identity,
                                             to: roster.recipients(for: .team), at: now)
            paths.append(path)
        }
        if !writes.isEmpty { try store.putAll(writes) }
        return paths
    }

    /// Spec §5: one roster edit, leaders only (race loop as `approve`).
    public func setPolicy(_ policy: TeamRoster.Policy) throws {
        try editRoster { current in
            var next = current
            next.policy = policy
            return next
        }
    }

    // MARK: status

    public func status() throws -> TeamStatus {
        let r = roster?.doc
        let role = isLeader ? "leader" : (isMember ? "member" : "pending")
        let requests = isLeader ? (try requests().count) : 0
        return TeamStatus(id: config.id, name: config.name, remote: config.remote, kid: identity.kid,
                          role: role, rev: r?.rev, leaders: r?.leaders.count ?? 0,
                          members: r?.members.count ?? 0, requests: requests)
    }
}
