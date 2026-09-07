import Foundation
import InfinitusCore

/// Persistence for the tray's Lock pane. `LockPolicy` is the state
/// machine (InfinitusCore); this is the Windows file behind it.
///
/// Windows Hello / CredUI is omitted — LocalAuthentication has no
/// counterpart wired here, so turning the lock on skips a biometric
/// prompt and just arms the policy. Sleep/wake are also unhooked
/// (no NSWorkspace); `.onSleep` is stored but never fires until a
/// later phase feeds `LockPolicy.sleep()` / `wake(at:)`.
public enum WinLockStore {
    public static var url: URL {
        WinSettingsStore.infinitusHome.appendingPathComponent("lock.json")
    }

    public struct File: Codable, Equatable, Sendable {
        public var enabled: Bool
        public var relock: Int
        public init(enabled: Bool = false, relock: Int = LockPolicy.Relock.default.rawValue) {
            self.enabled = enabled
            self.relock = relock
        }
    }

    public static let relockLabels: [(LockPolicy.Relock, String)] = [
        (.immediately, "Immediately"),
        (.fiveMinutes, "After 5 minutes"),
        (.oneHour, "After 1 hour"),
        (.onSleep, "When the PC sleeps"),
    ]

    public static func load(from url: URL = url) -> LockPolicy {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else {
            return LockPolicy()
        }
        return LockPolicy(enabled: LockSetting.enabled(stored: file.enabled),
                          relock: LockSetting.relock(stored: file.relock))
    }

    public static func save(_ policy: LockPolicy, to url: URL = url) throws {
        let file = File(enabled: policy.enabled, relock: policy.relock.rawValue)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: url, options: .atomic)
    }

    /// Names of teams this box is in — for the off-while-in-a-team
    /// warning. Reads config files only (never TeamClient.open).
    public static func teamNames() -> [String] {
        let paths = TeamPaths.standard()
        return paths.teamIDs().compactMap { id in
            (try? Data(contentsOf: paths.configFile(id)))
                .flatMap { try? CanonicalJSON.decode(TeamConfig.self, from: $0) }?.name
        }
    }
}
