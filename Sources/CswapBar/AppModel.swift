import Foundation
import SwiftUI
import CswapCore

/// Main-actor state the MenuBarExtra renders. Feeds per spec §2:
/// snapshots from `cswap list --json` (timer + right after any switch
/// event), events from the supervised `cswap auto --json`.
@MainActor
final class AppModel: ObservableObject {
    @Published var accounts: [Account] = []
    @Published var activeNumber: Int?
    @Published var engineState: EngineSupervisor.State = .stopped
    @Published var eventLog: [String] = []
    @Published var lastError: String?

    let cli: CswapCLI?
    private var supervisor: EngineSupervisor?
    private var refreshTask: Task<Void, Never>?

    var title: String {
        guard let active = accounts.first(where: { $0.active }) else { return "⌥" }
        let name = active.alias ?? String(active.email.prefix(while: { $0 != "@" }))
        var parts = ["⌥ \(name)"]
        if let pct = active.usage?.fiveHour?.pct { parts.append("\(Int(pct))%") }
        if let pct = active.usage?.sevenDay?.pct { parts.append("\(Int(pct))%") }
        return parts.joined(separator: " ")
    }

    init() {
        if let path = CswapLocator.locate() {
            cli = CswapCLI(binaryPath: path)
        } else {
            cli = nil
            lastError = "cswap not found — install it (uv tool install claude-swap)"
        }
    }

    func startFeeds() {
        guard let cli else { return }
        startEngine(binary: cli.binaryPath)
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshSnapshot()
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            }
        }
    }

    private func startEngine(binary: String) {
        let supervisor = EngineSupervisor(
            binaryPath: binary,
            onLine: { [weak self] line in
                Task { @MainActor in self?.consume(line) }
            },
            onState: { [weak self] state in
                Task { @MainActor in self?.engineState = state }
            }
        )
        self.supervisor = supervisor
        Task { await supervisor.start() }
    }

    private func consume(_ line: EventLine) {
        switch line {
        case .event(let event):
            eventLog.append(event.summary)
            if eventLog.count > 100 { eventLog.removeFirst(eventLog.count - 100) }
            switch event.kind {
            case "switch":
                Notifier.post(title: "claude-swap", body: event.summary)
                Task { await refreshSnapshot() }
            case "session-resumed":
                Notifier.post(title: "claude-swap", body: event.summary)
            case "account-unquarantined":
                Notifier.post(title: "claude-swap", body: "account back in rotation")
            case "all-exhausted":
                Notifier.post(title: "claude-swap", body: "every account is at its limit")
            default:
                break
            }
        case .schemaMismatch(let version):
            engineState = .schemaMismatch(version)
        case .garbage:
            break  // logged upstream; never fatal (spec §2)
        }
    }

    func refreshSnapshot() async {
        guard let cli else { return }
        do {
            let list = try await cli.accountList()
            accounts = list.accounts
            activeNumber = list.activeAccountNumber
            lastError = nil
        } catch {
            // Keep the last good snapshot rather than blanking the menu —
            // same policy as the rumps menubar's _worker.
            lastError = "\(error)"
        }
    }

    func switchTo(_ number: Int) {
        guard let cli else { return }
        Task {
            do {
                try await cli.switchTo(number)
                await refreshSnapshot()
            } catch { lastError = "\(error)" }
        }
    }

    func rotate() {
        guard let cli else { return }
        Task {
            do {
                try await cli.rotate()
                await refreshSnapshot()
            } catch { lastError = "\(error)" }
        }
    }
}
