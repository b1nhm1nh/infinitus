import Foundation

/// Layer 2 of #17: the phone sends a reply or a decision into a Claude
/// Code session on the Mac. The wire types compile everywhere (the phone
/// encodes/decodes them); delivery is macOS-only, same split as
/// `SessionFeed`/`SessionFeedReader`.
public enum SessionInput {
    /// Wire body of `POST /sessions/<pid>/input`.
    public struct Request: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable { case message, key }
        public let kind: Kind
        /// `message`: free text. `key`: one of `SessionInput.allowedKeys`.
        public let text: String

        public init(kind: Kind, text: String) {
            self.kind = kind
            self.text = text
        }
    }

    public struct Reply: Codable, Sendable, Equatable {
        /// "delivered" | "running" | "captured" | "noSurface" | "noChannel" | "rejected"
        public let outcome: String
        /// "pty" | "socket" — set only when `outcome == "delivered"`.
        public let channel: String?
        public let detail: String?

        public init(outcome: String, channel: String? = nil, detail: String? = nil) {
            self.outcome = outcome
            self.channel = channel
            self.detail = detail
        }
    }

    /// Number keys select an option and Enter confirms it in Claude
    /// Code's menus; `y`/`n` cover the plain confirm prompts.
    public static let allowedKeys: Set<String> = [
        "y", "n", "1", "2", "3", "4", "5", "6", "7", "8", "9", "enter", "esc",
    ]
}

#if !os(iOS)
extension SessionInput {
    static let maxMessageLength = 4000

    /// Non-empty, within the length cap, and free of control characters
    /// other than newline (a stray Tab/CR/ESC byte from a malformed
    /// client should never reach a real terminal).
    static func isValidMessage(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= maxMessageLength else { return false }
        for scalar in text.unicodeScalars where scalar != "\n" {
            if scalar.properties.generalCategory == .control { return false }
        }
        return true
    }

    /// Delivers one phone-sent input into the session's terminal (or, for
    /// a message, its peer socket) — the send side of layer 1's read-only
    /// feed. `hosts`/`claudeDir` come from the same `PtyHosts.available()`
    /// / `ClaudeSessions.configHome()` call `ResumeService` makes.
    public static func deliver(
        request: Request,
        record: ClaudeSessionRecord,
        hosts: [any PtyHost],
        claudeDir: URL,
        ttyOfPid: (Int32) -> String? = ProcessFacts.tty(of:),
        ancestorsOf: (Int32) -> [Int32] = ProcessFacts.ancestors(of:),
        socketSend: (ClaudeSessionRecord, String) -> Bool = { record, text in
            PeerSocket.send(socketPath: record.messagingSocketPath, text: text,
                            pid: record.pid, claudeDir: ClaudeSessions.configHome())
        },
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> Reply {
        let tty = ttyOfPid(record.pid)
        let ancestors = ancestorsOf(record.pid)

        switch request.kind {
        case .key:
            guard allowedKeys.contains(request.text) else {
                return Reply(outcome: "rejected", detail: "unsupported key")
            }
            for host in hosts {
                switch PtyNudge.press(host: host, pid: record.pid, key: request.text,
                                      tty: tty, ancestors: ancestors, sleep: sleep) {
                case .delivered, .typedUnverified:
                    return Reply(outcome: "delivered", channel: "pty")
                case .running:
                    return Reply(outcome: "running")
                case .capturedInput, .noSurface:
                    continue
                }
            }
            return Reply(outcome: "noSurface")

        case .message:
            guard isValidMessage(request.text) else {
                return Reply(outcome: "rejected", detail: "invalid message")
            }
            var sawRunning = false
            var sawCaptured = false
            // A terminal submits on every newline: one typed line, the
            // socket keeps the message's own line breaks.
            let typed = request.text.split(separator: "\n", omittingEmptySubsequences: true)
                .joined(separator: " ")
            for host in hosts {
                switch PtyNudge.nudge(host: host, pid: record.pid, text: typed,
                                      tty: tty, ancestors: ancestors, sleep: sleep) {
                case .delivered, .typedUnverified:
                    return Reply(outcome: "delivered", channel: "pty")
                case .running:
                    sawRunning = true
                case .capturedInput:
                    sawCaptured = true
                case .noSurface:
                    continue
                }
            }
            if !record.messagingSocketPath.isEmpty, socketSend(record, request.text) {
                return Reply(outcome: "delivered", channel: "socket")
            }
            if sawRunning { return Reply(outcome: "running") }
            if sawCaptured { return Reply(outcome: "captured") }
            // No surface anywhere and no socket to try either — there is
            // simply no way into this session, distinct from "there's a
            // terminal but it wouldn't take input".
            if record.messagingSocketPath.isEmpty { return Reply(outcome: "noChannel") }
            return Reply(outcome: "noSurface")
        }
    }
}
#endif
