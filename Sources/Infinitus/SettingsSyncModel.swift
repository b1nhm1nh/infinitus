import SwiftUI
import CswapCore

/// File-based settings sync through iCloud Drive (SyncSnapshot has the
/// scope and the why-not-KVS note). One file, deterministic tick, last
/// writer wins with remote preferred:
///   remote changed since last seen → pull; local drifted → push;
///   otherwise remember what we saw. Runs on the snapshot refresh tick,
/// so "eventual" is at most one refresh interval behind.
@MainActor
final class SettingsSyncModel: ObservableObject {
    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: "icloud_sync")
            if enabled {
                Task { await tick() }
            } else {
                lastSeen = nil
                status = nil
            }
        }
    }
    @Published var status: String?

    private var lastSeen: SyncSnapshot?
    private let defaults = UserDefaults.standard
    private weak var model: AppModel?

    /// Display prefs that travel. Per-machine state (pinned popup, debug
    /// menu, update bookkeeping, the sync toggle itself) stays home.
    static let boolKeys: Set<String> = [
        "show_account_name", "title_scoped", "title_remaining", "title_icon_only",
        "compact_rows", "footer_actions_hidden",
        "update_auto_check", "update_auto_install", "keep_awake", "auto_order",
        "sort_headroom",
        "push_sessions_done", "push_all_dead", "push_last_alive",
    ]
    static let intKeys: Set<String> = ["refresh_interval"]
    static let doubleKeys: Set<String> = ["glass_focused"]
    static let stringKeys: Set<String> = [
        "title_pct", "gamification_style", "popup_layout", "popup_text_size",
        "burn_style",
    ]
    static var appKeys: Set<String> {
        boolKeys.union(intKeys).union(doubleKeys).union(stringKeys)
    }

    init() {
        enabled = UserDefaults.standard.bool(forKey: "icloud_sync")
    }

    func attach(model: AppModel) { self.model = model }

    static func containerDir(home: String = NSHomeDirectory()) -> URL? {
        let drive = URL(fileURLWithPath:
            "\(home)/Library/Mobile Documents/com~apple~CloudDocs")
        guard FileManager.default.fileExists(atPath: drive.path) else { return nil }
        return drive.appendingPathComponent("Infinitus")
    }

    func tick() async {
        guard enabled else { return }
        guard let dir = Self.containerDir() else {
            status = "iCloud Drive not available on this Mac"
            return
        }
        let url = dir.appendingPathComponent("settings-sync.json")
        let local = await localSnapshot()
        // Re-check after the await: disabling mid-tick cleared the status,
        // and a stale in-flight tick must not push anyway (observed as
        // "pushed 00:23" under an off toggle, 2026-08-30).
        guard enabled else { return }
        let remote = (try? Data(contentsOf: url)).flatMap(SyncSnapshot.decode)
        if let remote, remote != lastSeen, remote != local {
            // Remote moved (another Mac wrote, or first tick over an
            // existing file): adopt it. Remote wins a two-sided race — the
            // file IS the shared truth.
            await apply(remote)
            lastSeen = remote
            status = "pulled \(Self.stamp())"
        } else if remote != local {
            do {
                try FileManager.default.createDirectory(
                    at: dir, withIntermediateDirectories: true)
                try local.encoded().write(to: url)
                lastSeen = local
                status = "pushed \(Self.stamp())"
            } catch {
                status = "push failed: \(error.localizedDescription)"
            }
        } else if lastSeen == nil {
            lastSeen = remote
            status = "in sync"
        }
    }

    /// Manual export/import of the same snapshot the sync file carries
    /// (user request 2026-08-30) — the sharing path for machines that
    /// don't share an iCloud account. Same scope rules: never
    /// credentials or push secrets.
    func export(to url: URL) async {
        do {
            try await localSnapshot().encoded().write(to: url)
            status = "exported \(Self.stamp())"
        } catch {
            status = "export failed: \(error.localizedDescription)"
        }
    }

    func importConfig(from url: URL) async {
        guard let snap = (try? Data(contentsOf: url)).flatMap(SyncSnapshot.decode)
        else {
            status = "import failed: not a Infinitus settings file"
            return
        }
        await apply(snap)
        // The imported state is now the local truth. Mark the sync file's
        // CURRENT content as seen: the next tick then reads remote as
        // unchanged and pushes the import, instead of treating the old
        // remote as news and pulling it back over the import.
        if let dir = Self.containerDir() {
            let syncURL = dir.appendingPathComponent("settings-sync.json")
            lastSeen = (try? Data(contentsOf: syncURL)).flatMap(SyncSnapshot.decode)
        }
        status = "imported \(Self.stamp())"
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date())
    }

    private func localSnapshot() async -> SyncSnapshot {
        var app: [String: JSONValue] = [:]
        // Only explicitly-set keys travel; on the other side absent keys
        // are left alone, so factory defaults never overwrite a choice.
        for key in Self.appKeys where defaults.object(forKey: key) != nil {
            if Self.boolKeys.contains(key) {
                app[key] = .bool(defaults.bool(forKey: key))
            } else if Self.intKeys.contains(key) {
                app[key] = .number(Double(defaults.integer(forKey: key)))
            } else if Self.doubleKeys.contains(key) {
                app[key] = .number(defaults.double(forKey: key))
            } else if let s = defaults.string(forKey: key) {
                app[key] = .string(s)
            }
        }
        var engine: [String: String] = [:]
        if let cli = model?.cli, let cfg = try? await cli.configList() {
            for entry in cfg.settings where entry.isSet {
                engine[entry.key] = entry.value.editableText
            }
        }
        return SyncSnapshot(app: app, themes: RowTheme.loadCustom(), engine: engine)
    }

    private func apply(_ snap: SyncSnapshot) async {
        for (key, value) in snap.app where Self.appKeys.contains(key) {
            switch value {
            case .bool(let b): defaults.set(b, forKey: key)
            case .number(let n):
                if Self.doubleKeys.contains(key) { defaults.set(n, forKey: key) }
                else { defaults.set(Int(n), forKey: key) }
            case .string(let s): defaults.set(s, forKey: key)
            default: break
            }
        }
        model?.reloadPrefs()
        if snap.themes != RowTheme.loadCustom() {
            try? RowTheme.saveCustom(snap.themes)
            model?.reloadCustomThemes()
        }
        // Engine settings: set what differs, unset what the snapshot lost —
        // without the unset leg two Macs ping-pong a removed key forever.
        if let cli = model?.cli, let current = try? await cli.configList() {
            for entry in current.settings {
                let want = snap.engine[entry.key]
                let have = entry.isSet ? entry.value.editableText : nil
                if let want, want != have {
                    _ = try? await cli.run(["config", "set", entry.key, want])
                } else if want == nil, entry.isSet {
                    _ = try? await cli.run(["config", "unset", entry.key])
                }
            }
        }
    }
}
