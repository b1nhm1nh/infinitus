import Foundation

// MARK: - Fleet mirror seam (#9)
//
// The mobile companion has no access to any machine's `cswap` binary —
// it reads a snapshot some Mac already captured. `listJSON` is the
// verbatim `cswap list --json` payload; consumers re-decode it with the
// existing `AccountList` decoder so the engine's models never need to
// grow Encodable conformance for this one seam.

public struct MirrorSnapshot: Codable, Sendable {
    public let capturedAt: Date
    public let machineName: String
    public let listJSON: Data
    public let sessions: [SessionPanelRow]
    /// Display prefs (#9 phase C1: "Follow Mac") — optional so snapshots
    /// captured before this field existed still decode.
    public let prefs: FleetPrefs?

    public init(capturedAt: Date, machineName: String, listJSON: Data,
                sessions: [SessionPanelRow], prefs: FleetPrefs? = nil) {
        self.capturedAt = capturedAt
        self.machineName = machineName
        self.listJSON = listJSON
        self.sessions = sessions
        self.prefs = prefs
    }
}

/// The Mac's display preferences, mirrored so "Follow Mac" can render
/// the iOS popup exactly as the Mac shows it (#9 phase C1).
public struct FleetPrefs: Codable, Sendable, Equatable {
    public let themeID: String
    public let compactRows: Bool
    public let popupLayout: String  // "wide" / "stacked" / "hstack"
    public let burnStyle: String
    public let introStyle: String
    public let introTitle: String
    public let introSpeed: Double
    public let customThemes: [RowTheme]

    public init(themeID: String = "off", compactRows: Bool = false,
                popupLayout: String = "wide", burnStyle: String = "ember",
                introStyle: String = "top", introTitle: String = "zoom",
                introSpeed: Double = 1.0, customThemes: [RowTheme] = []) {
        self.themeID = themeID
        self.compactRows = compactRows
        self.popupLayout = popupLayout
        self.burnStyle = burnStyle
        self.introStyle = introStyle
        self.introTitle = introTitle
        self.introSpeed = introSpeed
        self.customThemes = customThemes
    }
}

/// Where the mobile companion reads its latest fleet snapshot from.
/// `nil` means "no snapshot yet" (not an error); a decode failure is.
public protocol FleetMirror: Sendable {
    func latest() async throws -> MirrorSnapshot?
}

/// Reads a `MirrorSnapshot` written by `MirrorWriter` — the local
/// App Support copy today, an iCloud/CloudKit-synced copy once #9 lands.
public struct FileFleetMirror: FleetMirror {
    public let url: URL
    public init(url: URL) {
        self.url = url
    }

    public func latest() async throws -> MirrorSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(MirrorSnapshot.self, from: data)
    }
}

public enum MirrorWriter {
    public static func write(_ snapshot: MirrorSnapshot, to url: URL) throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(snapshot)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Atomic, not replaceItemAt — this file compiles for the Linux
        // tray and (now) iOS too, where the Darwin-only replacement API
        // isn't available everywhere.
        try data.write(to: url, options: .atomic)
    }

    /// One export per 30s — the tray is a fresh process per poll, so
    /// callers persist `lastWrite` in a sidecar file rather than memory.
    public static func shouldWrite(lastWrite: Date?, now: Date, minInterval: TimeInterval = 30) -> Bool {
        guard let lastWrite else { return true }
        return now.timeIntervalSince(lastWrite) > minInterval
    }

    /// `$XDG_STATE_HOME/infinitus` (fallback `~/.local/state/infinitus`) —
    /// same layout TrayHistory uses for usage history on Linux.
    public static func linuxStateDir(env: [String: String], home: String) -> URL {
        let base = env["XDG_STATE_HOME"] ?? home + "/.local/state"
        return URL(fileURLWithPath: base).appendingPathComponent("infinitus")
    }
}

public enum MirrorError: Error, Sendable {
    case notConfigured
}

/// Real implementation waits on the Apple Developer account (#9) —
/// deliberately no `import CloudKit` and no entitlements until then.
public struct CloudKitFleetMirror: FleetMirror {
    public init() {}

    public func latest() async throws -> MirrorSnapshot? {
        throw MirrorError.notConfigured
    }
}
