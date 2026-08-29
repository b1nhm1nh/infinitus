import SwiftUI
import CswapCore

/// Update state: engine version vs the latest claude-swap on PyPI.
/// The check is cheap (one JSON fetch, cached PyPI-side); the upgrade runs
/// `cswap upgrade` and DISPLAYS its transcript instead of interpreting it —
/// what uv/pipx do for this machine's install method isn't ours to guess.
@MainActor
final class UpdateModel: ObservableObject {
    @Published var current: String?
    @Published var latest: String?
    @Published var updateAvailable = false
    @Published var status: String?
    @Published var upgradeOutput: String?
    @Published var busy = false
    @Published var autoCheck: Bool { didSet { defaults.set(autoCheck, forKey: "update_auto_check") } }
    @Published var autoInstall: Bool { didSet { defaults.set(autoInstall, forKey: "update_auto_install") } }

    private let cli: CswapCLI?
    /// Set at wiring: bounces the supervised engine after a real upgrade
    /// (the child stays the OLD binary until respawned).
    var restartEngine: (() -> Void)?
    private let defaults = UserDefaults.standard
    private static let pypiURL = URL(string: "https://pypi.org/pypi/claude-swap/json")!

    init(cli: CswapCLI?) {
        self.cli = cli
        autoCheck = defaults.object(forKey: "update_auto_check") as? Bool ?? true
        autoInstall = defaults.object(forKey: "update_auto_install") as? Bool ?? false
    }

    /// Launch + every hour: check when due (24h since the last one, same
    /// cadence as the CLI's own passive checker) — not on every wake.
    func startAutoCheck() {
        Task { [weak self] in
            while !Task.isCancelled {
                if let self, self.autoCheck {
                    let last = self.defaults.double(forKey: "update_last_check")
                    if Date().timeIntervalSince1970 - last > 24 * 3600 {
                        await self.check(notify: true)
                    }
                }
                try? await Task.sleep(nanoseconds: 3600 * 1_000_000_000)
                if self == nil { return }
            }
        }
    }

    func check(notify: Bool = false) async {
        guard let cli, !busy else { return }
        busy = true
        defer { busy = false }
        status = nil
        do {
            current = try await cli.version()
            let (data, _) = try await URLSession.shared.data(from: Self.pypiURL)
            struct PyPI: Decodable {
                struct Info: Decodable { let version: String }
                let info: Info
            }
            let fetched = try JSONDecoder().decode(PyPI.self, from: data).info.version
            latest = fetched
            defaults.set(Date().timeIntervalSince1970, forKey: "update_last_check")
            guard let cur = current,
                  let a = PackageVersion(cur), let b = PackageVersion(fetched) else {
                status = "version strings did not parse; not comparing"
                updateAvailable = false
                return
            }
            updateAvailable = a < b
            if updateAvailable {
                status = "\(fetched) is available (you run \(cur))"
                if notify, defaults.string(forKey: "update_notified_version") != fetched {
                    defaults.set(fetched, forKey: "update_notified_version")
                    Notifier.post(title: "claude-swap",
                                  body: "update available: \(fetched) (you run \(cur))")
                }
                if autoInstall,
                   defaults.string(forKey: "update_attempted_version") != fetched {
                    defaults.set(fetched, forKey: "update_attempted_version")
                    // performUpgrade, not upgrade(): check() still holds
                    // `busy`, and upgrade()'s guard would silently bail —
                    // the unattended path would be a permanent no-op (the
                    // version is already marked attempted).
                    await performUpgrade()
                }
            } else {
                status = "up to date"
            }
        } catch {
            status = "check failed: \(error.localizedDescription)"
        }
    }

    func upgrade() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        await performUpgrade()
    }

    private func performUpgrade() async {
        guard let cli else { return }
        status = "running cswap upgrade…"
        let before = current
        do {
            let result = try await cli.upgrade()
            upgradeOutput = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            current = try? await cli.version()
            if let now = current, now != before {
                status = "updated to \(now) — engine restarted"
                updateAvailable = false
                restartEngine?()
                Notifier.post(title: "claude-swap", body: "updated to \(now)")
            } else {
                // Real case for a --from <path> install: the command runs,
                // the version stays. Surfaced, never retried silently.
                status = "upgrade ran (exit \(result.status)), still at \(before ?? "?")"
                if autoInstall {
                    Notifier.post(title: "claude-swap",
                                  body: "auto-update ran but the version is unchanged — see Settings → About")
                }
            }
        } catch {
            status = "upgrade failed: \(error.localizedDescription)"
        }
    }
}

/// About + updates. The update path touches the PYTHON tool only —
/// CswapBar.app itself has no distribution channel; it rebuilds from the
/// repo (make-app.sh).
struct AboutPane: View {
    @ObservedObject var model: UpdateModel

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "dev"
    }
    private var appBuild: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("CswapBar") {
                    Text(appBuild.map { "\(appVersion) (\($0))" } ?? appVersion)
                        .monospacedDigit()
                }
                LabeledContent("cswap engine") {
                    Text(model.current ?? "—").monospacedDigit()
                }
                LabeledContent("Author") {
                    Link("deathemperor", destination:
                        URL(string: "https://github.com/deathemperor")!)
                }
                LabeledContent("Project") {
                    Link("deathemperor/claude-swap", destination:
                        URL(string: "https://github.com/deathemperor/claude-swap")!)
                }
                LabeledContent("Changelog") {
                    Link("release notes", destination: changelogURL)
                }
            }
            Section("Updates") {
                Text("Updates apply to the cswap engine (from PyPI). "
                     + "The app itself rebuilds from the repo.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(model.busy ? "Checking…" : "Check for updates") {
                        Task { await model.check() }
                    }
                    .disabled(model.busy)
                    if model.updateAvailable {
                        Button("Update now") { Task { await model.upgrade() } }
                            .disabled(model.busy)
                            .buttonStyle(.borderedProminent)
                    }
                    Spacer()
                    if let latest = model.latest {
                        Text("latest: \(latest)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let status = model.status {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(model.updateAvailable ? Color.orange : .secondary)
                }
                Toggle("Check automatically (daily)", isOn: $model.autoCheck)
                Toggle("Install updates automatically", isOn: $model.autoInstall)
                    .help("When a newer version appears, run `cswap upgrade` "
                          + "unattended and restart the engine. Off: notify only.")
                if let output = model.upgradeOutput, !output.isEmpty {
                    DisclosureGroup("upgrade output") {
                        ScrollView {
                            Text(output)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 160)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { if model.current == nil { Task { await model.check() } } }
    }

    private var changelogURL: URL {
        // Release notes live on the upstream repo (the PyPI package's home).
        if model.updateAvailable, let latest = model.latest {
            return URL(string: "https://github.com/realiti4/claude-swap/releases/tag/v\(latest)")!
        }
        return URL(string: "https://github.com/realiti4/claude-swap/releases")!
    }
}
