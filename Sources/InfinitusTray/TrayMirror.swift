import Foundation
import CswapCore

/// Linux side of the fleet mirror (#9 phase 1 parity — macOS has
/// `MirrorExporter`). The tray is a fresh process per poll, so the last
/// write time can't live in memory; it's a sidecar timestamp file next
/// to the snapshot, same shape as `TrayHistory`'s last-poll marker.
enum TrayMirror {
    static var stateDir: URL {
        MirrorWriter.linuxStateDir(env: ProcessInfo.processInfo.environment,
                                   home: NSHomeDirectory())
    }

    static var url: URL { stateDir.appendingPathComponent("mirror-snapshot.json") }
    static var stampURL: URL { stateDir.appendingPathComponent("mirror-snapshot.lastwrite") }

    static func export(raw: Data, sessions: [SessionPanelRow], enginePath: String,
                        prefs: FleetPrefs,
                        progressByPid: [Int: SessionProgress]? = nil,
                        now: Date = Date()) {
        // The demo engine's fabricated fleet must not reach the mobile
        // companion (same gate TrayHistory uses).
        guard !enginePath.hasSuffix("demo-cswap") else { return }
        let last = (try? String(contentsOf: stampURL, encoding: .utf8))
            .flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .map { Date(timeIntervalSince1970: $0) }
        guard MirrorWriter.shouldWrite(lastWrite: last, now: now) else { return }
        let snapshot = MirrorSnapshot(
            capturedAt: now,
            machineName: ProcessInfo.processInfo.hostName,
            listJSON: raw,
            sessions: sessions,
            prefs: prefs,
            // No `cswap usage --json` cash cache on Linux today (#9
            // phase D1a) — TrayHistory only tracks headroom, not spend.
            usageJSON: nil,
            // No status-page poller and no engine supervisor in the tray
            // (#9 phase D2): it's a fresh process per Waybar tick, so the
            // phone's footer simply drops those two chips for a Linux
            // snapshot. The sessions card's progress the tray DOES have.
            serviceStatus: nil,
            engine: nil,
            progressByPid: progressByPid)
        guard (try? MirrorWriter.write(snapshot, to: url)) != nil else { return }
        try? String(now.timeIntervalSince1970).write(to: stampURL, atomically: true, encoding: .utf8)
    }
}
