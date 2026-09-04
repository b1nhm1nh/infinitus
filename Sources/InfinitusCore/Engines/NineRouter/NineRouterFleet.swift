import Foundation

/// Shared 9Router fleet provider and cache for Windows and macOS.
///
/// Polls 9Router's dashboard API via `NineRouterEngine`, caching the
/// decoded `[EngineFleet]` and primary Claude `AccountList` with a 30s TTL.
/// Exposes non-blocking synchronous reads for tray menus, GDI account panels,
/// and snapshot routes.
public enum NineRouterFleet {
    public static let cacheSeconds: TimeInterval = 30
    public static let timeout: TimeInterval = 20

    public enum SwitchOutcome: Sendable, Equatable {
        case switched(to: Int)
        case noEngine
        case failed(detail: String)

        public var message: String {
            switch self {
            case .switched(let number): return "switched to account \(number)"
            case .noEngine: return "no swap engine installed"
            case .failed(let detail):
                return detail.isEmpty ? "engine refused the switch" : detail
            }
        }
    }

    public struct StoredConfig: Codable, Sendable {
        public var baseURL: String
        public var password: String

        public init(baseURL: String, password: String) {
            self.baseURL = baseURL
            self.password = password
        }
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var cachedFleets: [EngineFleet]?
    private nonisolated(unsafe) static var cachedList: AccountList?
    private nonisolated(unsafe) static var cachedAt: Date?
    private nonisolated(unsafe) static var isRefreshing = false
    private nonisolated(unsafe) static var activeEngine: NineRouterEngine?

    /// Location of persisted 9Router configuration ($APPDATA\Infinitus\9router.json).
    public static var configURL: URL {
        #if os(Windows)
        let roaming = ProcessInfo.processInfo.environment["APPDATA"]
            ?? "\(NSHomeDirectory())\\AppData\\Roaming"
        return URL(fileURLWithPath: roaming)
            .appendingPathComponent("Infinitus")
            .appendingPathComponent("9router.json")
        #else
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Infinitus").appendingPathComponent("9router.json")
        #endif
    }

    /// True when 9Router is configured, routed, or locally authenticated.
    /// Pinned off in tests when `INFINITUS_9ROUTER == ""` or `INFINITUS_CSWAP == ""`.
    public static func isAvailable() -> Bool {
        let env = ProcessInfo.processInfo.environment
        if env["INFINITUS_9ROUTER"] == "" || env["INFINITUS_CSWAP"] == "" {
            return false
        }
        if ClaudeCodeRouting.isRouted(ClaudeCodeRouting.anthropicBaseURL(), to: nil) {
            return true
        }
        if FileManager.default.fileExists(atPath: configURL.path) {
            return true
        }
        if NineRouterLocalAuth.cliToken() != nil {
            return true
        }
        return false
    }

    /// Decides whether 9Router should be the primary fleet provider.
    /// Matches macOS policy: routed engine wins; otherwise cswap wins if installed and populated.
    public static func shouldUseNineRouter() -> Bool {
        guard isAvailable() else { return false }
        if ClaudeCodeRouting.isRouted(ClaudeCodeRouting.anthropicBaseURL(), to: nil) {
            return true
        }
        if CswapLocator.locate() == nil {
            return true
        }
        return false
    }

    /// Resolves target base URL and password.
    public static func loadConfig() -> (baseURL: URL, password: String) {
        if let data = try? Data(contentsOf: configURL),
           let stored = try? JSONDecoder().decode(StoredConfig.self, from: data),
           let url = URL(string: stored.baseURL) {
            let base = ClaudeCodeRouting.origin(of: url) ?? url
            return (base, stored.password)
        }
        if let routed = ClaudeCodeRouting.anthropicBaseURL(),
           let origin = ClaudeCodeRouting.origin(of: routed) {
            return (origin, "")
        }
        return (NineRouterEngine.defaultBaseURL, "")
    }

    /// Returns the cached primary AccountList, triggering an asynchronous refresh if nil.
    public static func list(now: Date = Date(), wait: Bool = false) -> AccountList? {
        guard isAvailable() else { return nil }
        lock.lock()
        let list = cachedList
        let at = cachedAt
        lock.unlock()
        if list == nil && at == nil {
            refresh(now: now, wait: wait)
            lock.lock()
            let res = cachedList
            lock.unlock()
            return res
        }
        return list
    }

    /// Returns the cached EngineFleets across providers, triggering refresh if nil.
    public static func fleets(now: Date = Date(), wait: Bool = false) -> [EngineFleet]? {
        guard isAvailable() else { return nil }
        lock.lock()
        let f = cachedFleets
        let at = cachedAt
        lock.unlock()
        if f == nil && at == nil {
            refresh(now: now, wait: wait)
            lock.lock()
            let res = cachedFleets
            lock.unlock()
            return res
        }
        return f
    }

    /// Asynchronously refreshes 9Router fleets off the caller thread, or synchronously when wait=true.
    public static func refresh(force: Bool = false, now: Date = Date(), wait: Bool = false) {
        guard isAvailable() else { return }
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

        let work = {
            let (baseURL, password) = loadConfig()
            let engine = NineRouterEngine(baseURL: baseURL, password: password)
            let sem = DispatchSemaphore(value: 0)
            var fetchedFleets: [EngineFleet]?

            Task {
                do {
                    fetchedFleets = try await engine.snapshot()
                } catch {
                    // Failures keep prior cached fleets
                }
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + timeout)

            lock.lock()
            activeEngine = engine
            if let fetchedFleets {
                cachedFleets = fetchedFleets
                if let claudeFleet = fetchedFleets.first(where: { $0.provider == .claude }) {
                    cachedList = AccountList(
                        schemaVersion: 1,
                        activeAccountNumber: claudeFleet.activeNumber,
                        accounts: claudeFleet.accounts,
                        nextCandidate: claudeFleet.nextCandidate,
                        nextRecovery: claudeFleet.nextRecovery,
                        liveSessions: claudeFleet.liveSessions
                    )
                } else if let first = fetchedFleets.first {
                    cachedList = AccountList(
                        schemaVersion: 1,
                        activeAccountNumber: first.activeNumber,
                        accounts: first.accounts,
                        nextCandidate: first.nextCandidate,
                        nextRecovery: first.nextRecovery,
                        liveSessions: first.liveSessions
                    )
                }
            }
            cachedAt = Date()
            isRefreshing = false
            lock.unlock()
        }

        if wait {
            work()
        } else {
            Thread.detachNewThread {
                work()
            }
        }
    }

    /// Invalidate cache.
    public static func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        cachedFleets = nil
        cachedList = nil
        cachedAt = nil
    }

    /// Switches the active connection in 9Router.
    public static func switchTo(_ number: Int?) -> SwitchOutcome {
        guard isAvailable() else { return .noEngine }
        let (baseURL, password) = loadConfig()
        lock.lock()
        let engine = activeEngine ?? NineRouterEngine(baseURL: baseURL, password: password)
        let currentList = cachedList
        lock.unlock()

        let targetNumber: Int
        if let number {
            targetNumber = number
        } else if let candidate = currentList?.nextCandidate {
            targetNumber = candidate
        } else if let firstNonActive = currentList?.accounts.first(where: { !$0.active && !($0.disabled ?? false) })?.number {
            targetNumber = firstNonActive
        } else {
            return .failed(detail: "no candidate account to switch to")
        }

        let sem = DispatchSemaphore(value: 0)
        var outcome: SwitchOutcome = .failed(detail: "switch timed out")

        Task {
            do {
                try await engine.switchTo(fleet: .claude, number: targetNumber)
                outcome = .switched(to: targetNumber)
            } catch {
                let msg = (error as? EngineError)?.errorDescription ?? error.localizedDescription
                outcome = .failed(detail: msg)
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + timeout)
        invalidate()
        refresh(force: true)
        return outcome
    }
}
