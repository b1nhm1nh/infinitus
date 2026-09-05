import Foundation

/// `roster/team.json` (spec §5): who is in the team and with which keys.
/// Stored as `Signed<TeamRoster>`; `rev` only grows and only a leader of
/// the roster being replaced may sign the next one.
public struct TeamRoster: Codable, Equatable, Sendable {
    /// Where a member's files of one kind go (spec §1 audiences).
    public enum ShareTarget: Codable, Equatable, Sendable {
        case leaders, team, members([String])

        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let kids = try? c.decode([String].self) { self = .members(kids); return }
            switch try c.decode(String.self) {
            case "leaders": self = .leaders
            case "team": self = .team
            case let other: throw DecodingError.dataCorruptedError(in: c, debugDescription: "share target \(other)")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .leaders: try c.encode("leaders")
            case .team: try c.encode("team")
            case .members(let kids): try c.encode(kids)
            }
        }
    }

    public struct Member: Codable, Equatable, Sendable {
        public var keys: TeamKeys
        public var name: String
        public var since: Int
        public var founder: Bool
        public var devices: [String]
        /// Hint copied from the member's `now.json`; readers trust envelope
        /// recipients, never this.
        public var sharesTo: [String: ShareTarget]

        public init(keys: TeamKeys, name: String, since: Int, founder: Bool = false,
                    devices: [String] = [], sharesTo: [String: ShareTarget] = [:]) {
            self.keys = keys; self.name = name; self.since = since
            self.founder = founder; self.devices = devices; self.sharesTo = sharesTo
        }
    }

    public struct Removed: Codable, Equatable, Sendable {
        public var kid: String
        public var at: Int
        public init(kid: String, at: Int) { self.kid = kid; self.at = at }
    }

    public struct Policy: Codable, Equatable, Sendable {
        /// "open" | "code" | "off"
        public var requests: String
        public var membersSeeEachOther: Bool
        public init(requests: String = "code", membersSeeEachOther: Bool = false) {
            self.requests = requests; self.membersSeeEachOther = membersSeeEachOther
        }
    }

    public var schema: Int
    public var id: String
    public var name: String
    public var createdAt: Int
    public var leaders: [Member]
    public var members: [Member]
    public var removed: [Removed]
    public var policy: Policy
    public var rev: Int

    public init(id: String, name: String, createdAt: Int, leaders: [Member], members: [Member] = [],
                removed: [Removed] = [], policy: Policy = Policy(), rev: Int) {
        self.schema = 1
        self.id = id; self.name = name; self.createdAt = createdAt
        self.leaders = leaders; self.members = members; self.removed = removed
        self.policy = policy; self.rev = rev
    }

    public var everyone: [Member] { leaders + members }

    public func keys(for kid: String) -> TeamKeys? {
        everyone.first { $0.keys.kid == kid }?.keys
    }

    public func isLeader(_ kid: String) -> Bool {
        leaders.contains { $0.keys.kid == kid }
    }

    /// Leaders always read; `.team` adds every member; `.members` adds the
    /// named ones that exist. The sender is added by `Envelope.seal`.
    public func recipients(for target: ShareTarget) -> [TeamKeys] {
        var out = leaders.map(\.keys)
        switch target {
        case .leaders: break
        case .team: out += members.map(\.keys)
        case .members(let kids): out += members.filter { kids.contains($0.keys.kid) }.map(\.keys)
        }
        return out
    }

    // MARK: acceptance

    public enum RosterError: Error, Equatable {
        case lowerRev, notALeader, badSignature, differentTeam, noLeaders
    }

    public enum Acceptance {
        /// `previous` is the roster this client last accepted (nil on the
        /// very first fetch). Anyone holding the store credential can write
        /// `roster/team.json`, so on that first roster listing the trusted
        /// leader is not enough: `trustRoot` — the leader kid the team code
        /// carried — must be the kid that SIGNED it.
        public static func check(_ candidate: Signed<TeamRoster>, previous: Signed<TeamRoster>?,
                                 trustRoot: String? = nil) throws {
            let roster = candidate.doc
            guard !roster.leaders.isEmpty else { throw RosterError.noLeaders }
            let authority = previous?.doc ?? roster
            if let previous {
                guard roster.id == previous.doc.id else { throw RosterError.differentTeam }
                guard roster.rev > previous.doc.rev else { throw RosterError.lowerRev }
            }
            if previous == nil, let trustRoot, candidate.by != trustRoot { throw RosterError.notALeader }
            guard let signer = authority.leaders.first(where: { $0.keys.kid == candidate.by }) else {
                throw RosterError.notALeader
            }
            do { try candidate.verify(with: signer.keys) } catch { throw RosterError.badSignature }
        }
    }
}
