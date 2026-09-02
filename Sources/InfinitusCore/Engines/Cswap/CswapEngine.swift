import Foundation

#if !os(iOS)
/// The claude-swap engine behind the `AccountEngine` seam (#8): one
/// Claude fleet, every capability, `list --json` bytes kept verbatim
/// for the mirror. The supervised `cswap auto` child stays
/// CswapSupervisor's job — this is the one-shot command side only.
public struct CswapEngine: AccountEngine {
    public static let engineID = "cswap"
    public let cli: CswapCLI

    public init(cli: CswapCLI) { self.cli = cli }

    public var id: String { Self.engineID }
    public var displayName: String { "cswap" }
    public var capabilities: EngineCapabilities { .all }

    public func snapshot() async throws -> [EngineFleet] {
        let (list, raw) = try await cli.accountListRaw()
        return [Self.fleet(from: list, raw: raw)]
    }

    /// Pure: the same mapping the launch cache used to apply by hand.
    public static func fleet(from list: AccountList, raw: Data?) -> EngineFleet {
        EngineFleet(engineID: engineID, provider: .claude,
                    accounts: list.accounts,
                    activeNumber: list.activeAccountNumber,
                    nextCandidate: list.nextCandidate,
                    nextRecovery: list.nextRecovery,
                    liveSessions: list.liveSessions,
                    raw: raw)
    }

    public func switchTo(fleet: Provider, number: Int) async throws {
        try await cli.switchTo(number)
    }
    public func rotate(fleet: Provider) async throws { try await cli.rotate() }
    public func reorder(fleet: Provider, _ numbers: [Int]) async throws {
        try await cli.reorder(numbers)
    }
    public func setHold(fleet: Provider, number: Int, held: Bool) async throws {
        try await cli.setRotation(number, enabled: !held)
    }
    public func rename(fleet: Provider, number: Int, _ name: String) async throws {
        try await cli.setAlias(number, name)
    }
    public func remove(fleet: Provider, number: Int) async throws {
        try await cli.removeAccount(number)
    }
    public func addCurrent() async throws { try await cli.addCurrent() }
    public func addToken(_ token: String) async throws { try await cli.addToken(token) }
    public func usageReport(days: Int) async throws -> UsageReport {
        try await cli.usageReport(days: days)
    }
}
#endif
