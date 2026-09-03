import Foundation

#if !os(iOS)
/// Where the `cswap` binary lives. Checked in order; first hit wins.
public enum CswapLocator {
    public static func defaultCandidates(home: String = NSHomeDirectory()) -> [String] {
        [
            "\(home)/.local/bin/cswap",
            "/opt/homebrew/bin/cswap",
            "/usr/local/bin/cswap",
        ]
    }

    public static func locate(
        candidates: [String]? = nil,
        exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        // Dev override: INFINITUS_CSWAP=/path pins the binary; the empty
        // string simulates a machine with no engine (onboarding testing —
        // a $HOME override can't fake it, NSHomeDirectory ignores $HOME).
        if candidates == nil,
           let forced = ProcessInfo.processInfo.environment["INFINITUS_CSWAP"] {
            return forced.isEmpty ? nil : (exists(forced) ? forced : nil)
        }
        return (candidates ?? defaultCandidates()).first(where: exists)
    }
}

public struct CLIError: Error, Sendable {
    public let message: String
    public init(message: String) { self.message = message }
}

/// Thin async wrapper over Process for one-shot cswap commands.
/// The supervised `cswap auto` child is CswapSupervisor's job, not this.
public struct CswapCLI: Sendable {
    public let binaryPath: String

    public init(binaryPath: String) { self.binaryPath = binaryPath }

    /// `stdin` feeds the child's standard input and closes it — the channel
    /// secrets travel on (`cswap notify slack -`), so they never appear in an
    /// argv another process could read out of `ps`.
    public func run(_ arguments: [String], stdin: String? = nil) async throws -> Data {
        // The blocking Process dance lives on a GCD thread, bridged by a
        // continuation. Running it inline in this async function blocked
        // whatever executor served it — on macOS 26 the body silently never
        // ran to completion (verified live 2026-08-29: "run() entered" then
        // nothing, no thread anywhere in the process holding the frames).
        let binaryPath = self.binaryPath
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: binaryPath)
                process.arguments = arguments
                let out = Pipe()
                process.standardOutput = out
                process.standardError = Pipe()
                if let stdin {
                    let input = Pipe()
                    process.standardInput = input
                    input.fileHandleForWriting.write(Data((stdin + "\n").utf8))
                    input.fileHandleForWriting.closeFile()
                }
                do {
                    try process.run()
                } catch {
                    cont.resume(throwing: error)
                    return
                }
                // Drain BEFORE waiting: a payload larger than the pipe buffer
                // would otherwise deadlock the child against an unread pipe.
                let data = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    cont.resume(throwing: CLIError(
                        message: "cswap \(arguments.joined(separator: " ")) exited \(process.terminationStatus)"))
                    return
                }
                cont.resume(returning: data)
            }
        }
    }

    public func accountList() async throws -> AccountList {
        try JSONDecoder().decode(AccountList.self, from: await run(["list", "--json"]))
    }

    /// Snapshot plus its raw bytes — the app caches the bytes so the
    /// next launch renders instantly instead of opening an empty shell
    /// while the subprocess runs (user 2026-08-30).
    public func accountListRaw() async throws -> (AccountList, Data) {
        let data = try await run(["list", "--json"])
        return (try JSONDecoder().decode(AccountList.self, from: data), data)
    }

    public func configList() async throws -> ConfigList {
        try JSONDecoder().decode(ConfigList.self, from: await run(["config", "list", "--json"]))
    }

    /// `cswap config set|unset` (nil unsets — the engine rejects an empty set).
    @discardableResult
    public func setConfig(_ key: String, _ value: String?) async throws -> Data {
        try await run(value.map { ["config", "set", key, $0] } ?? ["config", "unset", key])
    }

    @discardableResult
    public func switchTo(_ number: Int) async throws -> Data {
        try await run(["switch", String(number), "--json"])
    }

    @discardableResult
    public func rotate() async throws -> Data {
        try await run(["switch", "--json"])
    }

    @discardableResult
    public func reorder(_ numbers: [Int]) async throws -> Data {
        try await run(["reorder"] + numbers.map(String.init) + ["--json"])
    }

    /// Hold an account out of auto-rotation / return it (todo
    /// 2026-09-01: "option to disable (skip) accounts from rotation").
    @discardableResult
    public func setRotation(_ number: Int, enabled: Bool) async throws -> Data {
        // No --json: the engine scopes that flag to list/status/switch.
        try await run([enabled ? "enable" : "disable", String(number)])
    }

    /// Capture the CURRENTLY logged-in Claude Code account into the
    /// engine — the second half of the blessed relogin flow ("log in
    /// with Claude Code, then run: cswap add").
    @discardableResult
    public func addCurrent() async throws -> Data {
        try await run(["add"], stdin: "y")
    }

    /// Register a setup-token (or API key) with the engine — the token
    /// travels over stdin, never argv (`cswap add-token -`). cswap
    /// matches the credential's identity to an existing slot (relogin)
    /// or creates a new one (add). No --json: the engine only supports
    /// it on list/status/switch; success is exit 0.
    @discardableResult
    public func addToken(_ token: String) async throws -> Data {
        try await run(["add-token", "-"], stdin: token)
    }

    /// Remove an account slot. stdin pre-answers a confirmation prompt
    /// if the engine asks one (unread stdin is harmless if it doesn't).
    @discardableResult
    public func removeAccount(_ number: Int) async throws -> Data {
        try await run(["remove", String(number)], stdin: "y")
    }

    /// Set (non-empty) or remove (empty) an account's display alias.
    @discardableResult
    public func setAlias(_ number: Int, _ name: String) async throws -> Data {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty
            ? try await run(["alias", String(number), "--unset"])
            : try await run(["alias", String(number), trimmed])
    }

    public func history(limit: Int = 10) async throws -> SwitchHistoryList {
        try JSONDecoder().decode(
            SwitchHistoryList.self,
            from: await run(["history", "--json", "--limit", String(limit)]))
    }

    public func notifyStatus() async throws -> NotifyStatus {
        try JSONDecoder().decode(NotifyStatus.self, from: await run(["notify", "--json"]))
    }

    /// Multi-second call (streams ~GBs of transcripts) — callers refresh
    /// on demand, never on a timer.
    /// "cswap 0.26.0b1\n" -> "0.26.0b1".
    public func version() async throws -> String {
        let out = String(decoding: try await run(["--version"]), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out.split(separator: " ").last.map(String.init) ?? out
    }

    /// `cswap upgrade` with stdout and stderr MERGED into one transcript,
    /// exit status included — the caller displays the outcome rather than
    /// interpreting it (uv/pipx behavior for a --from <path> install isn't
    /// ours to guess). Never throws on a non-zero exit.
    public func upgrade() async throws -> (status: Int32, output: String) {
        let binaryPath = self.binaryPath
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: binaryPath)
                process.arguments = ["upgrade"]
                let out = Pipe()
                process.standardOutput = out
                process.standardError = out   // one reader, both streams
                do {
                    try process.run()
                } catch {
                    cont.resume(throwing: error)
                    return
                }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                cont.resume(returning: (
                    process.terminationStatus,
                    String(decoding: data, as: UTF8.self)
                ))
            }
        }
    }

    public func usageReport(days: Int) async throws -> UsageReport {
        try JSONDecoder().decode(
            UsageReport.self,
            from: await run(["usage", "--days", String(days), "--json"]))
    }

    /// Report plus raw bytes, for the app-side launch cache (the scan
    /// takes seconds; the cash column popped in late without it).
    public func usageReportRaw(days: Int) async throws -> (UsageReport, Data) {
        let data = try await run(["usage", "--days", String(days), "--json"])
        return (try JSONDecoder().decode(UsageReport.self, from: data), data)
    }
}

/// Masked away-push channel status from `cswap notify --json`. The fields
/// are DISPLAY strings ("hooks.slack.com…9xQz"), never the secrets.
public struct NotifyStatus: Decodable, Sendable {
    public let slackWebhookUrl: String?
    public let telegramBotToken: String?
    public let telegramChatId: String?
}
#endif
