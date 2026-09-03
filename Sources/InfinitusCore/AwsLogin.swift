import Foundation

/// AWS sign-in from the phone (user 2026-09-03: "sessions often need
/// `aws login` for SSO — identify those sessions, let me log in on
/// mobile, the session continues"). Pure parts live here: detecting the
/// need in a transcript, choosing the flow for a profile, reading the
/// CLI's prompts, and the wire shapes phone ↔ Mac. The Mac side runs
/// the CLI (AwsLoginRunner.swift); the phone renders `Item`s from the
/// snapshot and posts `StartRequest` / `CodeRequest`.
///
/// Two CLI flows, both built for exactly this: `aws login --remote`
/// prints a URL and then waits for the authorization code the browser
/// shows after sign-in; `aws sso login --use-device-code --no-browser`
/// prints a URL plus a user code and finishes by itself once the user
/// approves on any device. The code goes phone → Mac over the mirror
/// channel and straight into the CLI's stdin — never logged, never
/// stored. Infinitus never reads `~/.aws/login` or `~/.aws/sso`.
public enum AwsLogin {
    public enum Flow: String, Codable, Sendable {
        /// `aws login --remote`: URL, then a code pasted back.
        case remote
        /// `aws sso login --use-device-code --no-browser`: URL + code, no paste-back.
        case deviceCode
        /// `aws login` with the local browser callback — the Mac's own button.
        case local
        /// `aws login` with its localhost callback, the browser on the
        /// PHONE: the phone's web view intercepts the redirect to
        /// `http://127.0.0.1:<port>/oauth/callback?code=…` and posts it
        /// back; the Mac replays it against the CLI's own listener. No
        /// code to read or type (user 2026-09-03: "can the mobile app
        /// capture the code itself?").
        case relay
    }

    public enum Phase: String, Codable, Sendable {
        case starting, waitingForBrowser, waitingForCode, done, failed
    }

    /// One login in flight (or just finished), as the runner reports it.
    public struct State: Codable, Sendable, Equatable {
        public let profile: String
        public let flow: Flow
        public var phase: Phase
        /// The sign-in URL to open on the phone.
        public var url: String?
        /// Device-code flow: the code the page asks for.
        public var userCode: String?
        /// Relay flow: the port of the CLI's localhost callback listener.
        public var callbackPort: Int?
        /// Failure text (sanitized last output line) or the success line.
        public var message: String?
        public let startedAt: Double
        /// The session that needed it, if the login was started for one.
        public let pid: Int?
        public init(profile: String, flow: Flow, phase: Phase = .starting, url: String? = nil,
                    userCode: String? = nil, callbackPort: Int? = nil, message: String? = nil,
                    startedAt: Double, pid: Int?) {
            self.profile = profile
            self.flow = flow
            self.phase = phase
            self.url = url
            self.userCode = userCode
            self.callbackPort = callbackPort
            self.message = message
            self.startedAt = startedAt
            self.pid = pid
        }
    }

    /// What the snapshot carries: every session that needs a login,
    /// merged with the runner's state for that profile.
    public struct Item: Codable, Sendable, Equatable, Identifiable {
        public var id: String { "\(profile)|\(pid ?? 0)" }
        public let profile: String
        /// The flow the phone would start (`.remote` / `.deviceCode`).
        public let flow: Flow
        public let pid: Int?
        /// The session's display name (record name or repo folder).
        public let sessionLabel: String?
        public let state: State?
        public init(profile: String, flow: Flow, pid: Int?, sessionLabel: String?, state: State?) {
            self.profile = profile
            self.flow = flow
            self.pid = pid
            self.sessionLabel = sessionLabel
            self.state = state
        }
    }

    /// `POST /aws-login/start`.
    public struct StartRequest: Codable, Sendable, Equatable {
        public let profile: String
        public let pid: Int?
        /// The Mac's own browser flow instead of the phone one.
        public let local: Bool?
        /// Paste-back (`aws login --remote`) instead of the relay — for a
        /// client without an intercepting web view.
        public let remote: Bool?
        public init(profile: String, pid: Int? = nil, local: Bool? = nil, remote: Bool? = nil) {
            self.profile = profile
            self.pid = pid
            self.local = local
            self.remote = remote
        }
    }

    /// `POST /aws-login/code`.
    public struct CodeRequest: Codable, Sendable, Equatable {
        public let profile: String
        public let code: String
        public init(profile: String, code: String) {
            self.profile = profile
            self.code = code
        }
    }

    /// `POST /aws-login/callback`: the redirect the phone's web view
    /// intercepted, verbatim (`http://127.0.0.1:<port>/oauth/callback?…`).
    public struct CallbackRequest: Codable, Sendable, Equatable {
        public let profile: String
        public let url: String
        public init(profile: String, url: String) {
            self.profile = profile
            self.url = url
        }
    }

    public struct Reply: Codable, Sendable, Equatable {
        public let ok: Bool
        public let state: State?
        public let error: String?
        public init(ok: Bool, state: State? = nil, error: String? = nil) {
            self.ok = ok
            self.state = state
            self.error = error
        }
    }

    public static let startPath = "/aws-login/start"
    public static let codePath = "/aws-login/code"
    public static let callbackPath = "/aws-login/callback"
    /// A login that hasn't finished in this long is abandoned.
    public static let timeout: TimeInterval = 600

    // MARK: detection

    /// Signatures the CLI (and the cred broker in front of it) print when
    /// the sign-in has lapsed. Any match means "needs aws login".
    static let expiredMarkers = [
        "please reauthenticate using 'aws login'",
        "error when retrieving token from sso",
        "the sso session associated with this profile has expired",
        "the sso session has expired",
        "fix: aws login",
        "run: aws login",
        "please run: aws login",
    ]

    /// The profile a transcript excerpt says needs a login, or nil when
    /// the text carries no expired-session signature. `default` when the
    /// signature names no profile.
    public static func profile(in text: String) -> String? {
        let lower = text.lowercased()
        guard expiredMarkers.contains(where: { lower.contains($0) }) else { return nil }
        let pattern = #"aws (?:sso )?login(?: --remote)?(?: --profile[ =]([A-Za-z0-9._-]+))"#
        if let re = try? NSRegularExpression(pattern: pattern),
           let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let r = Range(m.range(at: 1), in: text) {
            return String(text[r])
        }
        return "default"
    }

    /// The profile the FAILED command addressed — `--profile X` or
    /// `AWS_PROFILE=X` in the Bash command — for the CLI's own error,
    /// which names no profile. Nil when the command names none.
    public static func profile(inCommand command: String) -> String? {
        let pattern = #"(?:--profile[ =]|AWS_PROFILE=)["']?([A-Za-z0-9._-]+)"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
              let r = Range(m.range(at: 1), in: command) else { return nil }
        return String(command[r])
    }

    /// Which flow signs a profile in from the phone, from the user's own
    /// `~/.aws/config` text: an SSO profile (`sso_session` /
    /// `sso_start_url`) takes the device-code flow, everything else the
    /// relay (`aws login` with the phone intercepting the callback).
    /// `.remote` stays the paste-back fallback a client may ask for.
    public static func flow(profile: String, configText: String) -> Flow {
        var inProfile = false
        for raw in configText.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                let name = line.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                    .trimmingCharacters(in: .whitespaces)
                inProfile = name == "profile \(profile)" || (profile == "default" && name == "default")
                continue
            }
            guard inProfile, let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            if key == "sso_session" || key == "sso_start_url" { return .deviceCode }
        }
        return .relay
    }

    public static func defaultConfigURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".aws/config")
    }

    // MARK: running

    /// The CLI invocation for a flow. `AWS_PAGER` is cleared by the runner.
    public static func arguments(profile: String, flow: Flow) -> [String] {
        switch flow {
        case .remote: return ["login", "--remote", "--profile", profile]
        case .deviceCode: return ["sso", "login", "--use-device-code", "--no-browser", "--profile", profile]
        case .local, .relay: return ["login", "--profile", profile]
        }
    }

    /// The localhost callback port in a plain `aws login` authorize URL
    /// (`redirect_uri=http%3A%2F%2F127.0.0.1%3A60861%2Foauth%2Fcallback`).
    public static func callbackPort(inURL url: String) -> Int? {
        guard let comps = URLComponents(string: url),
              let redirect = comps.queryItems?.first(where: { $0.name == "redirect_uri" })?.value,
              let r = URLComponents(string: redirect), r.host == "127.0.0.1" else { return nil }
        return r.port
    }

    /// A callback the Mac may replay: plain http to 127.0.0.1 on the
    /// CLI's own port, the CLI's own path — nothing else is fetched.
    public static func isValidCallback(_ url: String, port: Int) -> Bool {
        guard let c = URLComponents(string: url), c.scheme == "http", c.host == "127.0.0.1",
              c.port == port, c.path == "/oauth/callback",
              c.queryItems?.contains(where: { $0.name == "code" && !($0.value ?? "").isEmpty }) == true
        else { return false }
        return true
    }

    /// What the CLI's output so far tells us.
    public struct Prompt: Equatable, Sendable {
        public var url: String?
        public var userCode: String?
        /// The `--remote` flow is waiting for the pasted code.
        public var wantsCode = false
        /// The CLI printed its success line.
        public var succeeded = false
        public init() {}
    }

    public static func parseOutput(_ text: String) -> Prompt {
        var p = Prompt()
        let lines = text.replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        for (i, line) in lines.enumerated() {
            if p.url == nil, line.hasPrefix("https://") { p.url = line }
            if p.userCode == nil, line.lowercased().hasPrefix("then enter the code") {
                // Device-code flow: the code is the next non-empty line ("XXXX-XXXX").
                if let code = lines[(i + 1)...].first(where: { !$0.isEmpty }), isValidCode(code) {
                    p.userCode = code
                }
            }
            if line.lowercased().hasPrefix("enter the authorization code") { p.wantsCode = true }
            if line.hasPrefix("Updated profile") || line.lowercased().hasPrefix("successfully logged into") {
                p.succeeded = true
            }
        }
        return p
    }

    /// Codes are short, alphanumeric with dashes — anything else never
    /// reaches the CLI's stdin.
    public static func isValidCode(_ code: String) -> Bool {
        !code.isEmpty && code.count <= 128
            && code.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    /// The message the session gets once the login lands (SessionInput
    /// message path, same as the phone's replies).
    public static func continueMessage(profile: String, fromPhone: Bool) -> String {
        "AWS login for profile \(profile) completed\(fromPhone ? " from the phone" : ""). "
            + "Retry the command that needed it and continue."
    }
}
