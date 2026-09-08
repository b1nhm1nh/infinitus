import Foundation
import InfinitusCore

/// Windows home for `SessionProfiles` (#165). Same JSON as the Mac's
/// App Support file; path follows `%APPDATA%\Infinitus` unless
/// `INFINITUS_PROFILES` is set (the e2e hatch).
public enum WinProfilesStore {
    public static var url: URL {
        if let over = ProcessInfo.processInfo.environment["INFINITUS_PROFILES"], !over.isEmpty {
            return URL(fileURLWithPath: over)
        }
        return WinSettingsStore.infinitusHome.appendingPathComponent("session-profiles.json")
    }

    public static func load(from url: URL = url) -> [SessionProfile] {
        SessionProfiles.load(from: url)
    }

    public static func save(_ profiles: [SessionProfile], to url: URL = url) throws {
        try SessionProfiles.save(profiles, to: url)
    }
}
