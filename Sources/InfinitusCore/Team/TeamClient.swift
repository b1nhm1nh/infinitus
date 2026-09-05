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
    }

    public static let identitySecretName = "identity"
    public static func tokenName(_ id: String) -> String { "team.\(id).token" }

    public let config: TeamConfig
    public let identity: TeamIdentity
    public private(set) var roster: Signed<TeamRoster>?
    private let paths: TeamPaths
    private let secrets: TeamSecrets
    private let store: TeamGit

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

    public static func create(name: String, remote: String, token: String?, paths: TeamPaths,
                              secrets: TeamSecrets, now: Int = Int(Date().timeIntervalSince1970)) throws -> TeamClient {
        let me = try identity(paths: paths, secrets: secrets)
        let id = UUID().uuidString.lowercased()
        let config = TeamConfig(id: id, name: name, remote: remote, kid: me.kid, joinedAt: now, leaderKid: me.kid)
        if let token { try secrets.write(tokenName(id), Data(token.utf8)) }
        let store = TeamGit(dir: paths.storeDir(id), remote: remote, token: token, author: me.kid)
        try store.open()
        let roster = TeamRoster(id: id, name: name, createdAt: now,
                                leaders: [TeamRoster.Member(keys: me.keys, name: "Leader", since: now, founder: true)],
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
        return self.roster!.doc
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

    public func code(expiresIn seconds: Int = 7 * 86_400,
                     now: Int = Int(Date().timeIntervalSince1970)) throws -> String {
        guard isLeader else { throw ClientError.notALeader }
        let token = secrets.read(Self.tokenName(config.id)).map { String(decoding: $0, as: UTF8.self) }
        return try TeamCode(team: config.id, name: config.name, remote: config.remote, token: token,
                            leader: identity.keys, expires: now + seconds).encoded(by: identity)
    }

    public func requests() throws -> [Signed<TeamRequest>] {
        guard isLeader else { throw ClientError.notALeader }
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

    // MARK: files

    /// Seals `plaintext` to the audience plus every leader and pushes it
    /// under `m/<my kid>/<path>`. Returns the store path.
    @discardableResult
    public func publish(kind: String, path: String, plaintext: Data, audience: TeamRoster.ShareTarget,
                        now: Int = Int(Date().timeIntervalSince1970)) throws -> String {
        guard let roster = roster?.doc, isMember else { throw ClientError.notInTeam }
        let file = try Envelope.seal(plaintext, kind: kind, from: identity, to: roster.recipients(for: audience), at: now)
        let storePath = "m/\(identity.kid)/\(path)"
        try store.put(storePath, file)
        return storePath
    }

    /// Envelopes under `m/` that name me as a reader and come from someone
    /// in the roster. Reads headers only.
    public func readable() throws -> [StoreEntry] {
        guard let roster = roster?.doc else { return [] }
        return try store.list("m/").filter { entry in
            guard let data = try store.get(entry.path), let header = try? Envelope.header(of: data) else { return false }
            return roster.keys(for: header.from) != nil && header.to.contains { $0.kid == identity.kid }
        }
    }

    public func read(_ path: String) throws -> (Envelope.Header, Data) {
        guard let roster = roster?.doc else { throw ClientError.noRoster }
        guard let data = try store.get(path) else { throw Envelope.EnvelopeError.malformed }
        return try Envelope.open(data, as: identity, senderKey: { roster.keys(for: $0) })
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
