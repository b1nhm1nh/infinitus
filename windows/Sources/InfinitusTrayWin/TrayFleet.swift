import Foundation
import InfinitusCore

/// Account + usage lines for the Infinitus Windows tray.
///
/// Shells `cswap list --json` when claude-swap is installed, with a 30s cache
/// and non-blocking refresh on the tray's 5s timer tick.
/// Every failure yields nil or fallback lines, never throws, and never blocks
/// the UI thread.
enum TrayFleet {
    struct MenuLine: Equatable {
        let text: String
        let enabled: Bool
    }

    /// Cache duration matching CswapFleet (30s).
    static let cacheSeconds: TimeInterval = 30
    /// Engine command timeout.
    static let timeout: TimeInterval = 20

    private static let lock = NSLock()
    private nonisolated(unsafe) static var cachedList: AccountList?
    private nonisolated(unsafe) static var cachedAt: Date?
    private nonisolated(unsafe) static var isRefreshing = false

    /// Nil when no engine is installed — the caller then omits the section entirely.
    static func hasEngine() -> Bool {
        CswapLocator.locate() != nil
    }

    /// Account + usage lines for the tray menu, newest data within a cache window.
    /// Format per account: `<icon/alias or email> — <5h%> / <7d%>` with active marked.
    /// Summary line when no accounts: "no accounts — `cswap add` registers one".
    static func menuLines() -> [MenuLine] {
        guard hasEngine() else { return [] }
        lock.lock()
        let list = cachedList
        let at = cachedAt
        lock.unlock()

        if list == nil && at == nil {
            // First access: trigger asynchronous fetch so UI does not stall.
            refresh()
        }
        return formatLines(from: list)
    }

    /// Formats an AccountList (or nil) into menu lines.
    static func formatLines(from list: AccountList?, now: Date = Date()) -> [MenuLine] {
        guard let list else {
            return [MenuLine(text: "refreshing accounts…", enabled: false)]
        }
        guard !list.accounts.isEmpty else {
            return [MenuLine(text: "no accounts — `cswap add` registers one", enabled: false)]
        }

        return list.accounts.map { account in
            let active = account.active || (list.activeAccountNumber != nil && account.number == list.activeAccountNumber)
            let prefix = active ? "● " : "  "

            let name: String
            if let icon = account.icon, !icon.isEmpty {
                let identifier = account.alias ?? String(account.email.prefix(while: { $0 != "@" }))
                name = "\(icon) \(identifier)"
            } else if let alias = account.alias, !alias.isEmpty {
                name = alias
            } else {
                name = account.email
            }

            let usageText = formatUsage(account.usage, now: now)
            let fullText = "\(prefix)\(name) — \(usageText)"
            let clamped = fullText.count > 60 ? String(fullText.prefix(59)) + "…" : fullText
            return MenuLine(text: clamped, enabled: false)
        }
    }

    /// Formats 5h and 7d usage percentages: `<5h%> / <7d%>`.
    static func formatUsage(_ usage: Usage?, now: Date = Date()) -> String {
        guard let usage else { return "— / —" }

        let fiveText: String
        if let five = usage.fiveHour {
            fiveText = "\(Int(five.pct.rounded()))%"
        } else {
            fiveText = "—"
        }

        let sevenText: String
        if let seven = usage.sevenDay, let pct = WeeklyRoll.displayPct(seven, now: now) {
            sevenText = "\(Int(pct.rounded()))%"
        } else {
            sevenText = "—"
        }

        return "\(fiveText) / \(sevenText)"
    }

    /// Asynchronously refreshes account data if cache expired and no fetch is in flight.
    /// Safe to call on every 5s tray timer tick.
    static func refresh(force: Bool = false, now: Date = Date()) {
        guard hasEngine() else { return }

        lock.lock()
        if isRefreshing {
            lock.unlock()
            return
        }
        if !force, let at = cachedAt, now.timeIntervalSince(at) < cacheSeconds {
            lock.unlock()
            return
        }
        isRefreshing = true
        lock.unlock()

        Thread.detachNewThread {
            let fresh = executeRead()
            lock.lock()
            if let fresh {
                cachedList = fresh
            }
            cachedAt = Date()
            isRefreshing = false
            lock.unlock()
        }
    }

    /// Invalidate cache for manual refresh.
    static func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        cachedList = nil
        cachedAt = nil
    }

    /// Shells out to `cswap list --json` with timeout.
    private static func executeRead() -> AccountList? {
        guard let binary = CswapLocator.locate() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["list", "--json"]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        guard (try? process.run()) != nil else { return nil }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        _ = errors.fileHandleForReading.readDataToEndOfFile()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return try? JSONDecoder().decode(AccountList.self, from: data)
    }
}
