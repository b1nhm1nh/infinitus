import Foundation

/// Spec §7.1: what leaves the machine is redacted BEFORE it is sealed.
/// One regex pass per JSONL line; every replacement is plain ASCII
/// without quotes or backslashes, so a JSON line stays JSON. The
/// member's "What my team sees" view renders this same output.
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

    /// Order matters: a header rule eats "Bearer …" before the bare
    /// bearer rule sees it; the AWS id rule runs before the `.env` rule
    /// so `AWS_ACCESS_KEY_ID=AKIA…` reads as an AWS key, not a `.env` value.
    private static let rules: [(NSRegularExpression, String)] = [
        (re(#"(?i)authorization:\s*[^\s"'\\]+(?:\s+[^\s"'\\]+)?"#), "Authorization: [redacted]"),
        (re(#"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]{16,}"#), "Bearer [redacted]"),
        (re(#"\bsk-[A-Za-z0-9_-]{16,}"#), "[redacted-key]"),
        (re(#"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})"#), "[redacted-key]"),
        (re(#"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"#), "[redacted-aws-key]"),
        (re(#"(?i)(aws_secret_access_key|aws_session_token|secretaccesskey|sessiontoken)(\\?"?\s*[=:]\s*\\?"?)[A-Za-z0-9+/=]{16,}"#),
         "$1$2[redacted]"),
        (re(#"https://(?:hooks\.slack\.com|discord(?:app)?\.com/api/webhooks|outlook\.office\.com/webhook)/[^\s"'\\]+"#),
         "[redacted-webhook]"),
        (re(#"\b([A-Z][A-Z0-9_]*(?:KEY|SECRET|TOKEN|PASSWORD|PASSWD))=([^\s"'\\]+)"#), "$1=[redacted]"),
        // Any user's home, this machine's included: /Users/<x>, /home/<x>, /root.
        (re(#"(?<![A-Za-z0-9~])/(?:Users|home)/[^/\s"'\\]+|(?<![A-Za-z0-9~])/root(?=/|["'\s\\]|$)"#), "~"),
    ]

    private static let image = re(#""data"\s*:\s*"[A-Za-z0-9+/=]{256,}""#)

    public static func redact(_ line: String, options: Options) -> String {
        var out = line
        if options.home.count > 1 {
            let exact = re(NSRegularExpression.escapedPattern(for: options.home) + #"(?=/|["'\s\\]|$)"#)
            out = exact.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "~")
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
    public static func redact(jsonl: Data, options: Options) -> Data {
        let text = String(decoding: jsonl, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return Data(lines.map { redact(String($0), options: options) }.joined(separator: "\n").utf8)
    }
}
