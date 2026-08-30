import Foundation

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
        (candidates ?? defaultCandidates()).first(where: exists)
    }
}

public struct CLIError: Error, Sendable {
    public let message: String
}

/// Thin async wrapper over Process for one-shot cswap commands.
/// The supervised `cswap auto` child is EngineSupervisor's job, not this.
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
