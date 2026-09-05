import Foundation
import InfinitusCore

/// App preferences for the Windows tray — the subset of the Mac's
/// UserDefaults keys that mean anything here. Keys are the Mac's
/// verbatim (`title_pct`, `gamification_style`, …) so a settings file
/// exported on one platform imports on the other (SyncSnapshot.app).
public struct WinSettings: Codable, Equatable, Sendable {
    // Display / title
    public var showAccountName: Bool = true
    public var titlePct: String = "both"          // off | 5h | 7d | both
    public var titleScoped: Bool = false
    public var titleRemaining: Bool = false
    public var titleReset: String = "countdown"   // off | countdown | clock
    public var titleIconOnly: Bool = false
    public var refreshIntervalSeconds: Int = 60    // 30 | 60 | 300

    // Theme
    public var gamificationStyle: String = "off"

    // Push triggers (PushTriggers.Flags)
    public var pushSessionsDone: Bool = true
    public var pushAllDead: Bool = true
    public var pushLastAlive: Bool = true
    public var pushWaiting: Bool = true
    public var pushAwsLogin: Bool = true

    // Tray behaviour
    public var trayBalloonsEnabled: Bool = true
    public var sortByHeadroom: Bool = true

    // Engine toggles and updates
    public var engineCswapEnabled: Bool = true
    public var engineCLIProxyEnabled: Bool = false
    public var engineNineRouterEnabled: Bool = false
    public var updateAutoCheck: Bool = true
    public var updateAutoInstall: Bool = false
    public var updateLastCheck: Double = 0
    public var updateNotifiedVersion: String = ""
    public var updateAttemptedVersion: String = ""

    // Devices
    public var mirrorPort: UInt16 = 47824
    public var autoResume: Bool = false

    // Shell
    public var lastPaneID: String = "display"
    public var windowWidth: Int32 = 0     // 0 = use the default
    public var windowHeight: Int32 = 0

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case showAccountName = "show_account_name"
        case titlePct = "title_pct"
        case titleScoped = "title_scoped"
        case titleRemaining = "title_remaining"
        case titleReset = "title_reset"
        case titleIconOnly = "title_icon_only"
        case refreshIntervalSeconds = "refresh_interval"
        case gamificationStyle = "gamification_style"
        case pushSessionsDone = "push_sessions_done"
        case pushAllDead = "push_all_dead"
        case pushLastAlive = "push_last_alive"
        case pushWaiting = "push_waiting"
        case pushAwsLogin = "push_aws_login"
        case trayBalloonsEnabled = "tray_balloons"
        case sortByHeadroom = "sort_headroom"
        case engineCswapEnabled = "engine_cswap_enabled"
        case engineCLIProxyEnabled = "engine_cliproxy_enabled"
        case engineNineRouterEnabled = "engine_9router_enabled"
        case updateAutoCheck = "update_auto_check"
        case updateAutoInstall = "update_auto_install"
        case updateLastCheck = "update_last_check"
        case updateNotifiedVersion = "update_notified_version"
        case updateAttemptedVersion = "update_attempted_version"
        case mirrorPort = "mirror_port"
        case autoResume = "auto_resume"
        case lastPaneID = "last_pane"
        case windowWidth = "window_width"
        case windowHeight = "window_height"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WinSettings()
        showAccountName = try c.decodeIfPresent(Bool.self, forKey: .showAccountName) ?? d.showAccountName
        titlePct = try c.decodeIfPresent(String.self, forKey: .titlePct) ?? d.titlePct
        titleScoped = try c.decodeIfPresent(Bool.self, forKey: .titleScoped) ?? d.titleScoped
        titleRemaining = try c.decodeIfPresent(Bool.self, forKey: .titleRemaining) ?? d.titleRemaining
        titleReset = try c.decodeIfPresent(String.self, forKey: .titleReset) ?? d.titleReset
        titleIconOnly = try c.decodeIfPresent(Bool.self, forKey: .titleIconOnly) ?? d.titleIconOnly
        refreshIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .refreshIntervalSeconds) ?? d.refreshIntervalSeconds
        gamificationStyle = try c.decodeIfPresent(String.self, forKey: .gamificationStyle) ?? d.gamificationStyle
        pushSessionsDone = try c.decodeIfPresent(Bool.self, forKey: .pushSessionsDone) ?? d.pushSessionsDone
        pushAllDead = try c.decodeIfPresent(Bool.self, forKey: .pushAllDead) ?? d.pushAllDead
        pushLastAlive = try c.decodeIfPresent(Bool.self, forKey: .pushLastAlive) ?? d.pushLastAlive
        pushWaiting = try c.decodeIfPresent(Bool.self, forKey: .pushWaiting) ?? d.pushWaiting
        pushAwsLogin = try c.decodeIfPresent(Bool.self, forKey: .pushAwsLogin) ?? d.pushAwsLogin
        trayBalloonsEnabled = try c.decodeIfPresent(Bool.self, forKey: .trayBalloonsEnabled) ?? d.trayBalloonsEnabled
        sortByHeadroom = try c.decodeIfPresent(Bool.self, forKey: .sortByHeadroom) ?? d.sortByHeadroom
        engineCswapEnabled = try c.decodeIfPresent(Bool.self, forKey: .engineCswapEnabled) ?? d.engineCswapEnabled
        engineCLIProxyEnabled = try c.decodeIfPresent(Bool.self, forKey: .engineCLIProxyEnabled) ?? d.engineCLIProxyEnabled
        engineNineRouterEnabled = try c.decodeIfPresent(Bool.self, forKey: .engineNineRouterEnabled) ?? d.engineNineRouterEnabled
        updateAutoCheck = try c.decodeIfPresent(Bool.self, forKey: .updateAutoCheck) ?? d.updateAutoCheck
        updateAutoInstall = try c.decodeIfPresent(Bool.self, forKey: .updateAutoInstall) ?? d.updateAutoInstall
        updateLastCheck = try c.decodeIfPresent(Double.self, forKey: .updateLastCheck) ?? d.updateLastCheck
        updateNotifiedVersion = try c.decodeIfPresent(String.self, forKey: .updateNotifiedVersion) ?? d.updateNotifiedVersion
        updateAttemptedVersion = try c.decodeIfPresent(String.self, forKey: .updateAttemptedVersion) ?? d.updateAttemptedVersion
        mirrorPort = try c.decodeIfPresent(UInt16.self, forKey: .mirrorPort) ?? d.mirrorPort
        autoResume = try c.decodeIfPresent(Bool.self, forKey: .autoResume) ?? d.autoResume
        lastPaneID = try c.decodeIfPresent(String.self, forKey: .lastPaneID) ?? d.lastPaneID
        windowWidth = try c.decodeIfPresent(Int32.self, forKey: .windowWidth) ?? d.windowWidth
        windowHeight = try c.decodeIfPresent(Int32.self, forKey: .windowHeight) ?? d.windowHeight
    }
}

public enum WinSettingsStore {
    public static var url: URL {
        let roaming = ProcessInfo.processInfo.environment["APPDATA"]
            ?? "\(NSHomeDirectory())\\AppData\\Roaming"
        return URL(fileURLWithPath: roaming)
            .appendingPathComponent("Infinitus")
            .appendingPathComponent("settings.json")
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var cache: WinSettings?

    /// Formatter for bad settings file quarantine. Never uses named IANA zones per CLAUDE.md.
    private static let badStampFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyyMMdd-HHmmss"
        df.timeZone = TimeZone(secondsFromGMT: 0)
        return df
    }()

    public static func load(from fileURL: URL = url) -> WinSettings {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else {
            let def = WinSettings()
            cache = def
            return def
        }

        guard let data = try? Data(contentsOf: fileURL) else {
            let def = WinSettings()
            cache = def
            return def
        }

        do {
            let s = try JSONDecoder().decode(WinSettings.self, from: data)
            cache = s
            return s
        } catch {
            // Corrupt file: quarantine to settings.json.bad-<timestamp>
            let stamp = badStampFormatter.string(from: Date())
            let badURL = fileURL.deletingLastPathComponent()
                .appendingPathComponent("\(fileURL.lastPathComponent).bad-\(stamp)")
            try? fm.removeItem(at: badURL)
            try? fm.moveItem(at: fileURL, to: badURL)
            NSLog("Quarantined corrupt settings file to %@", badURL.path)

            let def = WinSettings()
            cache = def
            return def
        }
    }

    public static func save(_ s: WinSettings, to fileURL: URL = url) throws {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(s)

        let tmpURL = dir.appendingPathComponent("\(fileURL.lastPathComponent).tmp")
        try data.write(to: tmpURL, options: .atomic)

        // Windows atomic replace via remove + move
        if fm.fileExists(atPath: fileURL.path) {
            try fm.removeItem(at: fileURL)
        }
        try fm.moveItem(at: tmpURL, to: fileURL)
        cache = s
    }

    public static func update(fileURL: URL = url, _ mutate: (inout WinSettings) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        var current: WinSettings
        if let cached = cache {
            current = cached
        } else {
            let fm = FileManager.default
            if fm.fileExists(atPath: fileURL.path),
               let data = try? Data(contentsOf: fileURL),
               let decoded = try? JSONDecoder().decode(WinSettings.self, from: data) {
                current = decoded
            } else {
                current = WinSettings()
            }
        }
        mutate(&current)

        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(current)

        let tmpURL = dir.appendingPathComponent("\(fileURL.lastPathComponent).tmp")
        try data.write(to: tmpURL, options: .atomic)

        if fm.fileExists(atPath: fileURL.path) {
            try fm.removeItem(at: fileURL)
        }
        try fm.moveItem(at: tmpURL, to: fileURL)
        cache = current
    }

    /// Testing helper to reset in-memory cache
    public static func resetCache() {
        lock.lock()
        defer { lock.unlock() }
        cache = nil
    }
}
