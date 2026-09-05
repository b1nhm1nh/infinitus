import Foundation

/// Spec §7.1: what leaves the machine is redacted BEFORE it is sealed.
/// One regex pass per JSONL line; every replacement is plain ASCII
/// without quotes or backslashes, so a JSON line stays JSON. The
/// member's "What my team sees" view renders this same output.
/// These rules fail safe, not exact: prose containing a literal
/// `Authorization:` or a path under `/Users/x` can over-redact. That's
/// intentional — leaking a secret is worse than mangling a sentence.
public enum TeamRedaction {
    public struct Options {
        /// The member's home directory, normalised to `~`.
        public var home: String
        /// Pasted images ride as base64 blocks; dropped unless asked for.
        public var includeImages: Bool
        public init(home: String, includeImages: Bool = false) {
            self.home = home; self.includeImages = includeImages
        }
    }

    private static func re(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }

    /// Order matters: the `Authorization:` header rule eats "Bearer …"
    /// before the bare bearer rule sees it.
    ///
    /// A transcript line is JSON, so a multi-line tool result is one
    /// physical line where real newlines/tabs are the two-character JSON
    /// escapes `\n`/`\t`/`\r` — a secret can sit right after one of those
    /// instead of after a real word-boundary character. `B` is a leading
    /// boundary that accepts either, consumed into `$1` and replayed at
    /// the front of every affected replacement so the escape survives.
    private static let B = #"(^|[^A-Za-z0-9_]|\\[nrt])"#

    private static let rules: [(NSRegularExpression, String)] = [
        (re(#"(?i)authorization:\s*[^\s"'\\]+(?:\s+[^\s"'\\]+)?"#), "Authorization: [redacted]"),
        (re(#"(?i)"# + B + #"bearer\s+[A-Za-z0-9._~+/=-]{16,}"#), "$1Bearer [redacted]"),
        (re(B + #"sk-[A-Za-z0-9_-]{16,}"#), "$1[redacted-key]"),
        (re(B + #"(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})"#), "$1[redacted-key]"),
        (re(B + #"(?:AKIA|ASIA)[A-Z0-9]{16}\b"#), "$1[redacted-aws-key]"),
        (re(#"(?i)(aws_secret_access_key|aws_session_token|secretaccesskey|sessiontoken)(\\?"?\s*[=:]\s*\\?"?)[A-Za-z0-9+/=]{16,}"#),
         "$1$2[redacted]"),
        (re(#"https://(?:hooks\.slack\.com|discord(?:app)?\.com/api/webhooks|outlook\.office\.com/webhook)/[^\s"'\\]+"#),
         "[redacted-webhook]"),
        (re(B + #"([A-Z][A-Z0-9_]*(?:KEY|SECRET|TOKEN|PASSWORD|PASSWD))=([^\s"'\\]+)"#), "$1$2=[redacted]"),
        // Any user's home, this machine's included: /Users/<x>, /home/<x>, /root.
        // Zero-width lookbehind (not a capture) — no chars to replay.
        (re(#"(?<=^|[^A-Za-z0-9~]|\\[nrt])(?:/(?:Users|home)/[^/\s"'\\]+|/root(?=/|["'\s\\]|$))"#), "~"),
    ]

    private static let image = re(#""data"\s*:\s*"[A-Za-z0-9+/=]{256,}""#)

    private static func homeRegex(_ options: Options) -> NSRegularExpression? {
        guard options.home.count > 1 else { return nil }
        return re(NSRegularExpression.escapedPattern(for: options.home) + #"(?=/|["'\s\\]|$)"#)
    }

    public static func redact(_ line: String, options: Options) -> String {
        redact(line, options: options, home: homeRegex(options))
    }

    /// The per-line redactor with the home regex compiled once — what a
    /// publisher hands `TeamChunker`, which calls it for every line.
    public static func redactor(options: Options) -> (String) -> String {
        let home = homeRegex(options)
        return { redact($0, options: options, home: home) }
    }

    private static func redact(_ line: String, options: Options, home: NSRegularExpression?) -> String {
        var out = line
        if let home {
            out = home.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "~")
        }
        for (rule, template) in rules {
            out = rule.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        if !options.includeImages {
            out = image.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "\"data\":\"\"")
        }
        return out
    }

    /// Line by line; the trailing newline structure is kept exactly.
    /// The home regex is compiled once here rather than per line — a
    /// transcript can run to tens of thousands of lines.
    public static func redact(jsonl: Data, options: Options) -> Data {
        let text = String(decoding: jsonl, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let redact = redactor(options: options)
        return Data(lines.map { redact(String($0)) }.joined(separator: "\n").utf8)
    }
}
