import Foundation
import SwiftUI
import AppKit
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
    private var lastNotifiedActive: Int?

    // Display prefs, persisted to UserDefaults under the same names and
    // defaults as the rumps MenuBarSettings. @Published (not @AppStorage):
    // @AppStorage inside an ObservableObject never fires objectWillChange,
    // so the MenuBarExtra title would go stale.
    @Published var showAccountName: Bool { didSet { defaults.set(showAccountName, forKey: "show_account_name") } }
    @Published var titlePct: String { didSet { defaults.set(titlePct, forKey: "title_pct") } }
    @Published var titleScoped: Bool { didSet { defaults.set(titleScoped, forKey: "title_scoped") } }
    @Published var refreshInterval: Int { didSet { defaults.set(refreshInterval, forKey: "refresh_interval") } }
    @Published var gamification: String { didSet { defaults.set(gamification, forKey: "gamification_style") } }
    @Published var compactRows: Bool { didSet { defaults.set(compactRows, forKey: "compact_rows") } }
    // Deliberately NOT persisted: if a hidden icon survived a relaunch there
    // would be no UI left to unhide it from (the Settings window is only
    // reachable through the popup). Hiding lasts until quit.
    @Published var menuBarIconShown = true
    private let defaults = UserDefaults.standard

    var gamifiedRows: Bool { gamification == GamificationStyle.rpg.rawValue }

    var title: String {
        TitleFormatter.format(
            account: accounts.first(where: { $0.active }),
            prefs: TitlePrefs(showAccountName: showAccountName,
                              titlePct: titlePct, titleScoped: titleScoped))
    }

    init() {
        showAccountName = defaults.object(forKey: "show_account_name") as? Bool ?? true
        let pct = defaults.string(forKey: "title_pct") ?? "both"
        titlePct = TitlePrefs.pctChoices.contains(pct) ? pct : "both"
        titleScoped = defaults.object(forKey: "title_scoped") as? Bool ?? false
        let interval = defaults.object(forKey: "refresh_interval") as? Int ?? 60
        refreshInterval = TitlePrefs.refreshChoices.contains(interval) ? interval : 60
        let style = defaults.string(forKey: "gamification_style")
            ?? ((defaults.object(forKey: "gamified_rows") as? Bool ?? false) ? "rpg" : "off")
        gamification = GamificationStyle(rawValue: style) != nil ? style : "off"
        compactRows = defaults.object(forKey: "compact_rows") as? Bool ?? false
        if let path = CswapLocator.locate() {
            cli = CswapCLI(binaryPath: path)
        } else {
            cli = nil
            lastError = "cswap not found — install it (uv tool install claude-swap)"
        }
    }

    /// Idempotent: called from app init so the supervised engine starts at
    /// LAUNCH — a window-style MenuBarExtra may not build its content view
    /// until the first click, and rumps started its engine immediately.
    func startFeeds() {
        guard let cli, supervisor == nil else { return }
        startEngine(binary: cli.binaryPath)
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshSnapshot()
                // Read the pref each pass so an interval change applies on
                // the next tick without restarting the task.
                let seconds = await MainActor.run { self?.refreshInterval ?? 60 }
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
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
                Task { await refreshSnapshot() }  // the snapshot diff posts the notification
            case "session-resumed":
                Notifier.post(title: "claude-swap", body: event.summary)
            case "remote-control-rearmed":
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
            let previous = activeNumber
            // withAnimation: the pct texts carry .contentTransition(.numericText)
            // so a fresh snapshot rolls the digits (the token-burn feel)
            // instead of snapping them.
            withAnimation(.easeInOut(duration: 0.6)) {
                accounts = list.accounts
                activeNumber = list.activeAccountNumber
            }
            lastError = nil
            // Switch notifications come from this DISPLAY-feed diff, not the
            // engine's `switch` events: our engine is parked whenever another
            // host (rumps, cswap watch, cswap auto) holds the mutex, and a
            // parked engine sees no events — the 2026-08-28 silent-switch
            // bug. The diff sees every switch regardless of who executed it,
            // manual ones included.
            if let current = list.activeAccountNumber,
               let previous, previous != current, lastNotifiedActive != current {
                lastNotifiedActive = current
                let name = accounts.first(where: { $0.number == current })
                    .map { $0.alias ?? String($0.email.prefix(while: { $0 != "@" })) } ?? "#\(current)"
                Notifier.post(title: "claude-swap",
                              body: "switched to account \(current) (\(name))")
            }
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

    @Published var reorderError: String?

    /// Apply a drag-reorder: `order` is the account numbers in their new
    /// top-to-bottom sequence. Optimistically re-sorts the local rows so the
    /// row lands where it was dropped, then lets the snapshot confirm.
    /// Quit path: stop the supervised engine BEFORE the process dies, so
    /// the child never outlives the app holding the mutex (the engine also
    /// watches its stdin pipe for EOF as the backstop against a hard kill).
    func shutdown() {
        let supervisor = supervisor
        Task {
            await supervisor?.stop()
            await MainActor.run { NSApplication.shared.terminate(nil) }
        }
    }

    /// Rename = set/clear the account's cswap alias, so every frontend
    /// (TUI, CLI, popup) shows the same name.
    func rename(_ number: Int, to name: String) {
        guard let cli else { return }
        Task {
            do {
                try await cli.setAlias(number, name)
                reorderError = nil
            } catch { reorderError = "\(error)" }
            await refreshSnapshot()
        }
    }

    func reorder(_ order: [Int]) {
        guard let cli else { return }
        let index = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        accounts.sort { (index[$0.number] ?? 0) < (index[$1.number] ?? 0) }
        Task {
            do {
                _ = try await cli.reorder(order)
                reorderError = nil
            } catch { reorderError = "\(error)" }
            await refreshSnapshot()
        }
    }
}

/// The gamification styles the popup can render. New styles: add a case
/// here and a branch in AccountGrid — the Display pane picker follows.
enum GamificationStyle: String, CaseIterable {
    case off
    case rpg

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .rpg: return "RPG — HP/MP gauges + gold"
        }
    }
}
