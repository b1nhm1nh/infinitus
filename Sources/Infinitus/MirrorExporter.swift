import Foundation
import InfinitusCore

/// Writes a `MirrorSnapshot` after every live refresh so the (future)
/// mobile companion has something to read (#9 phase 1). Off the main
/// actor, mirroring UsageHistoryRecorder's shape — this is all file IO
/// plus the same Claude-Code-files-only session read the tray already
/// does (never an engine internal).
actor MirrorExporter {
    private let minInterval: TimeInterval = 30
    private var lastWrite: Date = .distantPast
    /// The LAN server's payload slot (#9), when the phone companion is
    /// on — it serves the very bytes written here, never a re-encode.
    private var payload: MirrorPayloadBox?

    func attach(payload: MirrorPayloadBox) {
        self.payload = payload
    }

    static let url: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask)[0]
            .appendingPathComponent("Infinitus/mirror-snapshot.json")
    }()

    func record(listJSON: Data, prefs: FleetPrefs,
                serviceStatus: ServiceStatusSummary, engine: EngineBadge) {
        guard Date().timeIntervalSince(lastWrite) > minInterval else { return }
        lastWrite = Date()
        let claudeDir = ClaudeSessions.configHome()
        // Same selection as InfinitusTray.swift's panel rows: busy/waiting
        // first, busy before waiting, capped at 6.
        let sessionRecords = ClaudeSessions.list(claudeDir: claudeDir)
            .filter { $0.status == "busy" || $0.status == "waiting" }
            .sorted { a, _ in a.status == "busy" }
        let now = Date()
        // One transcript read per record feeds both the panel row and the
        // sessions card's per-pid progress (#9 phase D2) — the card's own
        // rows come from listJSON's liveSessions, so a session outside
        // this busy/waiting six simply keeps its single line.
        var progressByPid: [Int: SessionProgress] = [:]
        let sessions = sessionRecords.prefix(6).map { record -> SessionPanelRow in
            let progress = SessionProgress.read(sessionId: record.sessionId,
                                                cwd: record.cwd, claudeDir: claudeDir)
            progressByPid[Int(record.pid)] = progress
            return SessionPanelRow.make(record: record, progress: progress, now: now)
        }
        // Cash column (#9 phase D1a): the cache UsagePane.swift's refresh
        // already writes, verbatim — no new subprocess, no engine call.
        let usageJSON = try? Data(contentsOf: UsageModel.cacheURL)
        let snapshot = MirrorSnapshot(
            capturedAt: now,
            machineName: Host.current().localizedName ?? "Mac",
            listJSON: listJSON,
            sessions: sessions,
            prefs: prefs,
            usageJSON: usageJSON,
            serviceStatus: serviceStatus,
            engine: engine,
            progressByPid: progressByPid)
        // Encoded once here rather than inside MirrorWriter so the LAN
        // server hands out the same bytes the file holds.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        payload?.set(data)
        try? FileManager.default.createDirectory(
            at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.url, options: .atomic)
    }
}
