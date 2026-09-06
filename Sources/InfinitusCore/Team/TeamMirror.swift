import Foundation

/// The phone's view of the Mac's team (spec §9, step 8): a token-gated
/// route family on the mirror, deliberately OUTSIDE `TeamNearby.routePrefix`
/// (`/team/*` answers LAN peers without the pairing token). The Mac side
/// answers from `TeamModel`; the phone side is `NetworkFleetMirror`.
public enum TeamMirror {
    public static let prefix = "/mirror/team"
    public static let aggregatesPath = prefix + "/aggregates"
    public static let memberPath = prefix + "/member"
    public static let transcriptPath = prefix + "/transcript"
    public static let approvePath = prefix + "/approve"
    public static let declinePath = prefix + "/decline"
    public static let joinPath = prefix + "/join"
    public static let codePath = prefix + "/code"

    public struct KidRequest: Codable, Equatable, Sendable {
        public var kid: String
        public init(kid: String) { self.kid = kid }
    }
    public struct JoinRequest: Codable, Equatable, Sendable {
        public var code: String
        public var name: String
        public init(code: String, name: String) { self.code = code; self.name = name }
    }
    public struct CodeRequest: Codable, Equatable, Sendable {
        public var days: Int
        /// true → an invite link (one-time nonce, auto-approved by the leader's Mac); false → a team code.
        public var invite: Bool
        public init(days: Int, invite: Bool) { self.days = days; self.invite = invite }
    }
    public struct ActionReply: Codable, Equatable, Sendable {
        public var ok: Bool
        public var error: String?
        public var code: String?
        public init(ok: Bool, error: String? = nil, code: String? = nil) { self.ok = ok; self.error = error; self.code = code }
    }
    public struct MemberReply: Codable, Equatable, Sendable {
        public var kid: String
        public var name: String
        public var summary: Stats.Summary?
        public var sessions: [TeamDocs.SessionRow]
        /// Session ids with a readable transcript.
        public var transcripts: [String]
        public init(kid: String, name: String, summary: Stats.Summary?, sessions: [TeamDocs.SessionRow], transcripts: [String]) {
            self.kid = kid; self.name = name; self.summary = summary; self.sessions = sessions; self.transcripts = transcripts
        }
    }

    private static let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
    private static func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }

    public static func memberQuery(kid: String, period: Stats.Period) -> String {
        "kid=\(encode(kid))&period=\(period.rawValue)"
    }
    public static func transcriptQuery(kid: String, session: String) -> String {
        "kid=\(encode(kid))&session=\(encode(session))"
    }
}
