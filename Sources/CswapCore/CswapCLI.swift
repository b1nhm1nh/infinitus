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
        try process.run()
        // Drain BEFORE waiting: a payload larger than the pipe buffer would
        // otherwise deadlock the child against an unread pipe.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CLIError(message: "cswap \(arguments.joined(separator: " ")) exited \(process.terminationStatus)")
        }
        return data
    }

    public func accountList() async throws -> AccountList {
        try JSONDecoder().decode(AccountList.self, from: await run(["list", "--json"]))
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

    public func notifyStatus() async throws -> NotifyStatus {
        try JSONDecoder().decode(NotifyStatus.self, from: await run(["notify", "--json"]))
    }
}

/// Masked away-push channel status from `cswap notify --json`. The fields
/// are DISPLAY strings ("hooks.slack.com…9xQz"), never the secrets.
public struct NotifyStatus: Decodable, Sendable {
    public let slackWebhookUrl: String?
    public let telegramBotToken: String?
    public let telegramChatId: String?
}
