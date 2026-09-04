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
        /// The account this line switches to when clicked, or nil for a
        /// caption ("refreshing accounts…", "no accounts"). The active
        /// account carries nil too: switching to where you already are is
        /// a no-op the engine would refuse.
        let account: Int?

        init(text: String, enabled: Bool, account: Int? = nil) {
            self.text = text
            self.enabled = enabled
            self.account = account
        }
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
            // Clickable unless it is where we already are, or the engine
            // has it held out of rotation — in both cases a click would
            // only earn a refusal.
            let selectable = !active && !(account.disabled ?? false)
            return MenuLine(text: clamped, enabled: selectable,
                            account: selectable ? account.number : nil)
        }
    }

    /// Formats 5h and 7d usage percentages: `<5h%> / <7d%>`.
    /// When session and weekly quotas are absent but scoped model quotas exist
    /// (e.g. Gemini/Antigravity via 9Router), formats the primary scoped window: `<model>: <pct>%`.
    static func formatUsage(_ usage: Usage?, now: Date = Date()) -> String {
        guard let usage else { return "— / —" }

        if usage.fiveHour == nil && usage.sevenDay == nil,
           let scoped = usage.scoped, !scoped.isEmpty {
            let first = scoped[0]
            let name = (first.name?.isEmpty == false) ? first.name! : "model"
            let pct = WeeklyRoll.displayPct(first, now: now) ?? first.pct
            return "\(name): \(Int(pct.rounded()))%"
        }

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

    /// The cached list as-is, without triggering a fetch — for a second
    /// view (the account panel) that renders the same data the menu does
    /// and must not shell out on its own paint.
    static func cached() -> AccountList? {
        lock.lock()
        let list = cachedList
        let at = cachedAt
        lock.unlock()
        if list == nil, at == nil { refresh() }
        return list
    }

    /// Invalidate cache for manual refresh.
    static func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        cachedList = nil
        cachedAt = nil
    }

    /// Asks the engine to switch, off the UI thread, then refreshes so the
    /// menu shows the new active account on its next open. `report` is
    /// called with a line fit for a balloon.
    ///
    /// CLAUDE.md: the engine owns account policy. This forwards a click
    /// and reports the engine's answer — including a refusal, verbatim,
    /// rather than a cheerful "switched" the engine never agreed to.
    static func requestSwitch(to number: Int?, report: @escaping @Sendable (String) -> Void) {
        guard hasEngine() else {
            report("no swap engine installed")
            return
        }
        Thread.detachNewThread {
            let outcome = switchTo(number)
            invalidate()
            refresh(force: true)
            report(outcome.message)
        }
    }

    /// What a switch attempt did. Mirrors the daemon's `CswapFleet` —
    /// separate processes, so the tray runs `cswap` itself rather than
    /// reaching through a daemon that may not be running.
    enum SwitchOutcome {
        case switched(to: Int)
        case noEngine
        case failed(detail: String)

        var message: String {
            switch self {
            case .switched(let number): return "switched to account \(number)"
            case .noEngine: return "no swap engine installed"
            case .failed(let detail):
                return detail.isEmpty ? "engine refused the switch" : detail
            }
        }
    }

    /// Why a `--json` run failed, in the engine's own words.
    ///
    /// cswap reports failures as JSON on STDOUT and leaves stderr empty
    /// (`{"error":{"type":"ConfigError","message":"No accounts are
    /// managed yet"}}`, exit 1 — verified 2026-09-04), so reading stderr
    /// alone shows a bare exit code in the balloon.
    static func failureDetail(output: Data, errors: Data, status: Int32) -> String {
        if let object = try? JSONSerialization.jsonObject(with: output) as? [String: Any] {
            if let error = object["error"] as? [String: Any],
               let message = error["message"] as? String, !message.isEmpty {
                return message
            }
            if let message = object["error"] as? String, !message.isEmpty {
                return message
            }
        }
        let text = String(decoding: errors, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            return text.split(separator: "\n").last.map(String.init) ?? text
        }
        return "`cswap switch` exited \(status)"
    }

    /// `cswap switch <n> --json`, or `cswap switch --json` to rotate.
    static func switchTo(_ number: Int?) -> SwitchOutcome {
        guard let binary = CswapLocator.locate() else { return .noEngine }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = number.map { ["switch", String($0), "--json"] } ?? ["switch", "--json"]
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        guard (try? process.run()) != nil else { return .failed(detail: "engine did not run") }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return .failed(detail: "`cswap switch` timed out")
        }
        guard process.terminationStatus == 0 else {
            return .failed(detail: failureDetail(output: data, errors: errorData,
                                                 status: process.terminationStatus))
        }
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        // A refusal can ride in the body on exit 0; balloon the reason
        // rather than a "switched" the engine never agreed to.
        if let object, object["error"] != nil {
            return .failed(detail: failureDetail(output: data, errors: errorData, status: 0))
        }
        if let object,
           let active = (object["activeAccountNumber"] as? NSNumber)?.intValue
                     ?? (object["active"] as? NSNumber)?.intValue {
            return .switched(to: active)
        }
        if let number { return .switched(to: number) }
        return .failed(detail: "rotated, but the engine didn't name the account")
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
