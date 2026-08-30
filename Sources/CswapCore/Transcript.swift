import Foundation

/// A live session whose transcript ends in a plan-limit stop.
public struct StoppedSession: Sendable, Equatable {
    public let sessionId: String
    public let pid: Int32
    public let cwd: String
    /// Peer socket, when the record carries one — the fallback channel.
    public let socketPath: String
    public let peerProtocol: Int
    /// The limit message as Claude Code rendered it; shown, never parsed.
    public let message: String
    /// The `uuid` of the limit-stop entry. A nudge that burns on stale
    /// credentials appends a NEW limit stop, so comparing identities tells
    /// "burned, nudge again" from "held for review, leave it alone". Empty
    /// disables verification for that session rather than guessing.
    public var stopUuid: String

    public init(sessionId: String, pid: Int32, cwd: String, socketPath: String = "",
                peerProtocol: Int = 0, message: String = "", stopUuid: String = "") {
        self.sessionId = sessionId
        self.pid = pid
        self.cwd = cwd
        self.socketPath = socketPath
        self.peerProtocol = peerProtocol
        self.message = message
        self.stopUuid = stopUuid
    }

    public var canUseSocket: Bool { !socketPath.isEmpty && peerProtocol == PeerSocket.protocolVersion }
}

/// The tail of a Claude Code transcript, read only to tell a terminal
/// limit stop from a retryable 429. Not a public API — versioned by
/// `peerProtocol` in the session record; everything here degrades to
/// "not a stop" rather than throwing.
public enum Transcript {
    /// Transcripts reach hundreds of MB; one entry with a large tool result
    /// can be a few hundred KB, so this holds the last handful with margin.
    static let tailBytes = 512 * 1024

    /// `~/.claude/projects/<slug>/<sessionId>.jsonl` — the slug is the cwd
    /// with every non-alphanumeric character replaced by `-`.
    public static func path(cwd: String, sessionId: String, claudeDir: URL) -> URL {
        let slug = String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        return claudeDir.appendingPathComponent("projects")
            .appendingPathComponent(slug)
            .appendingPathComponent("\(sessionId).jsonl")
    }

    /// Only conversation turns and a retryable mid-turn 429 say anything
    /// about whether work has stopped; bookkeeping entries are skipped.
    static func decidesTheTurn(_ entry: [String: Any]) -> Bool {
        let type = entry["type"] as? String
        if type == "user" || type == "assistant" { return true }
        return type == "system" && (entry["subtype"] as? String) == "api_error"
    }

    /// The last entry that decides whether work has stopped. Reads only
    /// the tail; partial first/last lines are skipped, never an error.
    public static func lastTurnEntry(at url: URL) -> [String: Any]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let blob = try? handle.readToEnd() else { return nil }
        for line in blob.split(separator: UInt8(ascii: "\n")).reversed() {
            guard line.first == UInt8(ascii: "{"),
                  let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            else { continue }
            if decidesTheTurn(entry) { return entry }
        }
        return nil
    }

    /// The terminal plan-limit turn: a synthetic assistant message with
    /// `isApiErrorMessage` and `error == "rate_limit"` and no retry
    /// bookkeeping. Retryable 429s are `system`/`api_error` entries Claude
    /// Code is still working on — nudging those would interrupt a turn.
    public static func isLimitStop(_ entry: [String: Any]?) -> Bool {
        guard let entry, (entry["type"] as? String) == "assistant",
              let flag = entry["isApiErrorMessage"] as? Bool, flag,
              (entry["error"] as? String) == "rate_limit"
        else { return false }
        return entry["retryAttempt"] == nil
    }

    public static func limitText(_ entry: [String: Any]) -> String {
        if let message = entry["message"] as? [String: Any],
           let content = message["content"] as? [[String: Any]] {
            for block in content where (block["type"] as? String) == "text" {
                if let text = block["text"] as? String { return text }
            }
        }
        return "usage limit reached"
    }

    /// Every live session whose transcript ends in a limit stop. Unlike the
    /// engine's version this does NOT require a messaging socket: a session
    /// reachable over a terminal PTY (herdr/tmux/cmux) is the motivating
    /// case, and the socket only gates the fallback channel.
    public static func findStopped(sessions: [ClaudeSessionRecord], claudeDir: URL) -> [StoppedSession] {
        var out: [StoppedSession] = []
        for session in sessions where !session.sessionId.isEmpty {
            let entry = lastTurnEntry(at: path(cwd: session.cwd, sessionId: session.sessionId,
                                              claudeDir: claudeDir))
            guard isLimitStop(entry), let entry else { continue }
            out.append(StoppedSession(
                sessionId: session.sessionId, pid: session.pid, cwd: session.cwd,
                socketPath: session.messagingSocketPath, peerProtocol: session.peerProtocol,
                message: limitText(entry), stopUuid: entry["uuid"] as? String ?? ""))
        }
        return out
    }

    /// What the transcript says about a nudge already delivered.
    public enum Verdict: Equatable, Sendable {
        /// Original stop unchanged (not picked up yet, or HELD for review —
        /// invisible from here) or our own user turn in the ~2s before its
        /// 429. Never re-nudged: a held message retried queues duplicates.
        case waiting
        /// A DIFFERENT limit stop: the nudge started a turn that was rejected
        /// on stale credentials — worth another nudge once they propagate.
        case burned(newStopUuid: String)
        /// Work is happening (or nothing can be verified). Done.
        case done
    }

    public static func verdict(_ stopped: StoppedSession, claudeDir: URL) -> Verdict {
        guard let entry = lastTurnEntry(at: path(cwd: stopped.cwd, sessionId: stopped.sessionId,
                                                claudeDir: claudeDir)) else { return .done }
        if isLimitStop(entry) {
            let uuid = entry["uuid"] as? String ?? ""
            return uuid == stopped.stopUuid ? .waiting : .burned(newStopUuid: uuid)
        }
        if (entry["type"] as? String) == "user" { return .waiting }
        return .done
    }
}
