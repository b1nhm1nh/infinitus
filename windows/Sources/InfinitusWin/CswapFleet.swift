import Foundation
import InfinitusCore

/// The account half of the snapshot, when this box runs the swap engine.
///
/// claude-swap ships a Windows wheel (`uv tool install claude-swap` →
/// `~/.local/bin/cswap.exe`), and CLAUDE.md's rule holds here exactly as
/// on the Mac: the engine is a `cswap … --json` subprocess and nothing
/// else — never a read of `~/.claude-swap-backup`, never a second policy
/// on top. Account policy (auto-swap, ordering, thresholds) stays the
/// engine's; this only reads what it reports.
///
/// Absent engine is the normal case, not an error: the daemon then serves
/// the account-less synthetic fleet and the phone hides that section.
enum CswapFleet {
    /// Matches the Mac's fleet key so the phone treats a Windows host's
    /// cswap fleet as the same engine, not a second one.
    static let engineID = "cswap"

    /// How long a list is reused. The engine polls Anthropic on its own
    /// schedule; re-shelling per phone poll would add nothing but load.
    static let cacheSeconds: TimeInterval = 30

    /// Longer than a cold `cswap list` (it may refresh a token), short
    /// enough that a wedged engine can't hold the phone's snapshot.
    static let timeout: TimeInterval = 20

    private static let lock = NSLock()
    private nonisolated(unsafe) static var cached: (list: AccountList?, at: Date)?

    /// `cswap list --json`, or nil when the engine isn't installed, times
    /// out, or answers something this build can't decode. Every failure is
    /// nil, never a throw — an engine hiccup must not take the session
    /// feed down with it.
    static func list(now: Date = Date()) -> AccountList? {
        lock.lock()
        defer { lock.unlock() }
        if let cached, now.timeIntervalSince(cached.at) < cacheSeconds {
            return cached.list
        }
        let fresh = read()
        cached = (fresh, now)
        return fresh
    }

    /// Drops the cache so the next snapshot re-shells — for a caller that
    /// just changed account state and wants the change visible now.
    static func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        cached = nil
    }

    private static func read() -> AccountList? {
        guard let binary = CswapLocator.locate() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["list", "--json"]
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        guard (try? process.run()) != nil else { return nil }

        // Read before waiting: a full pipe buffer would deadlock the child.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        _ = errors.fileHandleForReading.readDataToEndOfFile()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
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
