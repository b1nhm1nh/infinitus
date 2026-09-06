import Foundation
import InfinitusCore

/// CLIProxyAPI fleet cache and operations for Windows, paralleling NineRouterFleet.
public enum CLIProxyFleet {
    public static let cacheSeconds: TimeInterval = 30
    public static let timeout: TimeInterval = 20
    /// How long a decoded config (file read + DPAPI unprotect) is trusted
    /// before re-reading. `isAvailable()` is asked several times per tray
    /// tick; `invalidate()` drops the memo so a saved key counts at once.
    static let configTTL: TimeInterval = 5

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
        public var encryptedKey: Data

        public init(baseURL: String, encryptedKey: Data) {
            self.baseURL = baseURL
            self.encryptedKey = encryptedKey
        }
    }

    private static let lock = NSLock()
    /// Scoped locking for the Task bodies below — a bare `lock()` in an
    /// async context is a Swift 6 error.
    private static func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
    private nonisolated(unsafe) static var cachedFleets: [EngineFleet]?
    private nonisolated(unsafe) static var cachedAt: Date?
    private nonisolated(unsafe) static var isRefreshing = false
    /// ONE engine per (base URL, key), kept across refreshes: the engine's
    /// usage cache (`usageTTL`) and its ordinals live on the instance. A
    /// fresh engine per call re-fetched every credential's usage each 30 s
    /// and — worse — knew no credential names, so every switch / hold /
    /// rename / remove threw "no account #n in the last snapshot".
    private nonisolated(unsafe) static var activeEngine: CLIProxyEngine?
    private nonisolated(unsafe) static var activeConfig: (baseURL: URL, key: String)?
    private nonisolated(unsafe) static var configMemo: (config: (baseURL: URL, key: String)?, at: Date)?

    public static var configURL: URL {
        let roaming = ProcessInfo.processInfo.environment["APPDATA"]
            ?? "\(NSHomeDirectory())\\AppData\\Roaming"
        return URL(fileURLWithPath: roaming)
            .appendingPathComponent("Infinitus")
            .appendingPathComponent("cliproxy.json")
    }

    public static func isAvailable() -> Bool {
        loadConfig() != nil
    }

    public static func loadConfig() -> (baseURL: URL, key: String)? {
        let now = Date()
        lock.lock()
        if let memo = configMemo, now.timeIntervalSince(memo.at) < configTTL {
            lock.unlock()
            return memo.config
        }
        lock.unlock()
        let config = readConfig()
        lock.lock()
        configMemo = (config, now)
        lock.unlock()
        return config
    }

    private static func readConfig() -> (baseURL: URL, key: String)? {
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(StoredConfig.self, from: data),
              let url = URL(string: config.baseURL),
              let key = WinSecret.unprotect(config.encryptedKey), !key.isEmpty else {
            return nil
        }
        return (url, key)
    }

    /// The shared engine for `config`, replaced only when the config
    /// changed (a saved base URL or key).
    private static func sharedEngine(for config: (baseURL: URL, key: String)) -> CLIProxyEngine {
        lock.lock()
        defer { lock.unlock() }
        if let engine = activeEngine, let current = activeConfig,
           current.baseURL == config.baseURL, current.key == config.key {
            return engine
        }
        let engine = CLIProxyEngine(baseURL: config.baseURL, managementKey: config.key)
        activeEngine = engine
        activeConfig = config
        return engine
    }

    /// Marks the cache stale WITHOUT dropping the last known fleets —
    /// the next read refetches and swaps the data in when it lands, so a
    /// panel open across an invalidate keeps its rows instead of wiping.
    /// The config memo goes too, so a just-saved key counts now.
    public static func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        cachedAt = nil
        configMemo = nil
    }

    public static func fleets(now: Date = Date(), wait: Bool = false) -> [EngineFleet]? {
        guard isAvailable() else { return nil }
        lock.lock()
        let fleets = cachedFleets
        let at = cachedAt
        lock.unlock()

        // Cold or stale: refetch. Stale rows keep rendering meanwhile
        // (stale-while-revalidate) instead of collapsing to empty.
        if at.map({ now.timeIntervalSince($0) >= cacheSeconds }) ?? true {
            refresh(now: now, wait: wait)
        }
        return fleets
    }

    public static func refresh(now: Date = Date(), wait: Bool = false, force: Bool = false) {
        guard let cfg = loadConfig() else { return }
        lock.lock()
        if isRefreshing && !wait {
            lock.unlock()
            return
        }
        if !force, let at = cachedAt, now.timeIntervalSince(at) < cacheSeconds, cachedFleets != nil {
            lock.unlock()
            return
        }
        isRefreshing = true
        lock.unlock()

        let block = {
            defer {
                lock.lock()
                isRefreshing = false
                lock.unlock()
            }
            let engine = sharedEngine(for: cfg)
            let sem = DispatchSemaphore(value: 0)
            // Written by the Task, read here after the wait: under the
            // lock, because a fetch that outlives the timeout still
            // finishes and writes.
            var fetched: [EngineFleet]? = nil
            Task {
                let fleets = try? await engine.snapshot()
                locked { fetched = fleets }
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + timeout)

            lock.lock()
            if let fetched {
                cachedFleets = fetched
                cachedAt = Date()
            }
            lock.unlock()
        }

        if wait {
            block()
        } else {
            Thread.detachNewThread(block)
        }
    }

    public static func switchTo(_ number: Int, provider: Provider) -> SwitchOutcome {
        guard isAvailable() else { return .noEngine }
        if let failure = perform({ try await $0.switchTo(fleet: provider, number: number) }) {
            return .failed(detail: failure)
        }
        return .switched(to: number)
    }

    public static func setHold(_ number: Int, provider: Provider, held: Bool) -> Bool {
        guard isAvailable() else { return false }
        return perform { try await $0.setHold(fleet: provider, number: number, held: held) } == nil
    }

    public static func rename(_ number: Int, provider: Provider, name: String) -> Bool {
        guard isAvailable() else { return false }
        return perform { try await $0.rename(fleet: provider, number: number, name) } == nil
    }

    public static func setPreferred(_ number: Int, provider: Provider, on: Bool) -> Bool {
        guard isAvailable() else { return false }
        return perform { try await $0.setPreferred(fleet: provider, number: number, on) } == nil
    }

    public static func remove(_ number: Int, provider: Provider) -> Bool {
        guard isAvailable() else { return false }
        return perform { try await $0.remove(fleet: provider, number: number) } == nil
    }

    /// One engine action on the SHARED engine — the one whose last
    /// snapshot minted the ordinals the number refers to. With no
    /// snapshot yet (first action after launch) one is taken first,
    /// synchronously. nil on success, else the failure in the engine's
    /// words; the cache is invalidated and refreshed either way.
    private static func perform(_ action: @escaping @Sendable (CLIProxyEngine) async throws -> Void) -> String? {
        guard let cfg = loadConfig() else { return SwitchOutcome.noEngine.message }
        lock.lock()
        let primed = activeEngine != nil
        lock.unlock()
        if !primed { refresh(wait: true, force: true) }
        let engine = sharedEngine(for: cfg)

        let sem = DispatchSemaphore(value: 0)
        var failure: String? = "the proxy did not answer in time"
        Task {
            var result: String?
            do {
                try await action(engine)
            } catch {
                result = (error as? EngineError)?.errorDescription ?? error.localizedDescription
            }
            locked { failure = result }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + timeout)
        lock.lock()
        let outcome = failure
        lock.unlock()
        invalidate()
        refresh(wait: true, force: true)
        return outcome
    }
}
