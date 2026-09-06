import Foundation

/// What a store path says about the envelope it holds (spec §4.3). The
/// path is outside the envelope signature, so a valid envelope can be
/// replayed under another member's branch or under a path whose shape
/// names another kind; writers and readers both run `check` (#55).
public enum TeamKinds {
    public static let stats = "stats"
    public static let now = "now"
    public static let sessions = "sessions"
    public static let transcripts = "transcripts"
    public static let crashes = "crashes"
    public static let aggregates = "aggregates"
    /// The kinds a member publishes about itself (§7), in table order.
    public static let memberKinds = [stats, now, sessions, transcripts, crashes]

    public enum KindError: Error, Equatable { case badPath, kindMismatch, senderMismatch }

    /// The kind a path's shape names and, under `m/<kid>/`, the kid that
    /// must have sealed it. `roster/aggregates/…` names no sender: the
    /// caller decides which leaders may write there (plan 9).
    public static func expected(at path: String) -> (from: String?, kind: String)? {
        guard let (branch, rest) = StorePath.branch(of: path) else { return nil }
        let owner: String?
        if branch.hasPrefix("m/") {
            owner = String(branch.dropFirst(2))
        } else if branch == "roster" {
            owner = nil
        } else {
            return nil
        }
        let parts = rest.split(separator: "/").map(String.init)
        switch parts.count {
        case 1 where parts[0] == "now.json":
            return (owner, now)
        case 1 where parts[0] == "crashes.json":
            return (owner, crashes)
        case 2 where parts[0] == "days" && parts[1].hasSuffix(".json"):
            return (owner, stats)
        case 2 where parts[0] == "sessions" && parts[1] == "index.json":
            return (owner, sessions)
        case 2 where parts[0] == "aggregates" && parts[1].hasSuffix(".json"):
            return (owner, aggregates)
        case 3 where parts[0] == "transcripts" && parts[2].hasSuffix(".jsonl"):
            return (owner, transcripts)
        case 5 where parts[0] == "transcripts" && parts[2] == "subagents" && parts[4].hasSuffix(".jsonl"):
            return (owner, transcripts)
        default:
            return nil
        }
    }

    public static func check(kind: String, from: String, at path: String) throws {
        guard let want = expected(at: path) else { throw KindError.badPath }
        guard want.kind == kind else { throw KindError.kindMismatch }
        if let owner = want.from, owner != from { throw KindError.senderMismatch }
    }

    public static func check(_ header: Envelope.Header, at path: String) throws {
        try check(kind: header.kind, from: header.from, at: path)
    }
}
