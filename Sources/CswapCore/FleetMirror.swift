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

    public init(capturedAt: Date, machineName: String, listJSON: Data,
                sessions: [SessionPanelRow]) {
        self.capturedAt = capturedAt
        self.machineName = machineName
        self.listJSON = listJSON
        self.sessions = sessions
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
