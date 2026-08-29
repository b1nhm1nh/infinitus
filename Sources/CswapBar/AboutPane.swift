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

/// About + updates, CodexBar-style: hero card (icon, version, build,
/// tagline), an Updates group, full-row link rows with leading icons and a
/// trailing arrow, and a license footer. The update path still touches the
/// PYTHON tool only — CswapBar.app itself rebuilds from the repo.
struct AboutPane: View {
    @ObservedObject var model: UpdateModel
    @Environment(\.openURL) private var openURL

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "dev"
    }
    private var appBuild: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }
    /// Stamped nowhere in Info.plist, so read the truth: the executable's
    /// modification time IS the build time.
    private var buildDate: String? {
        guard let url = Bundle.main.executableURL,
              let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                  .contentModificationDate
        else { return nil }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 5) {
                    appMark
                        .padding(.bottom, 6)
                    Text("Limitless").font(.title2).bold()
                    Text(appBuild.map { "Version \(appVersion) (\($0))" }
                         ?? "Version \(appVersion)")
                        .foregroundStyle(.secondary)
                    if let buildDate {
                        Text("Built \(buildDate)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Every Claude account in one menu bar — swap before you stall.")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }

            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $model.autoCheck)
                Toggle("Install updates automatically", isOn: $model.autoInstall)
                    .help("When a newer version appears, run `cswap upgrade` "
                          + "unattended and restart the engine. Off: notify only.")
                LabeledContent {
                    HStack {
                        if model.updateAvailable {
                            Button("Update Now") { Task { await model.upgrade() } }
                                .disabled(model.busy)
                                .buttonStyle(.borderedProminent)
                        }
                        Button(model.busy ? "Checking…" : "Check for Updates…") {
                            Task { await model.check() }
                        }
                        .disabled(model.busy)
                    }
                } label: {
                    Text("cswap engine \(model.current ?? "—")")
                    if let latest = model.latest {
                        Text("latest on PyPI: \(latest)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let status = model.status {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(model.updateAvailable ? Color.orange : .secondary)
                }
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
                Text("Updates apply to the cswap engine (from PyPI). "
                     + "The app itself rebuilds from the repo.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Notifications") {
                LabeledContent("Delivery") {
                    Text(Notifier.lastAuthError == nil
                         ? "Notification Center" : "osascript fallback")
                }
                if let why = Notifier.lastAuthError {
                    Text(why).font(.caption).foregroundStyle(.secondary)
                    Text("Notification Center refuses builds signed with a "
                         + "bare Apple Development certificate (no provisioning "
                         + "profile). Alerts still arrive via osascript. For "
                         + "native banners the app needs a Developer ID "
                         + "signature, or one Xcode run with automatic signing "
                         + "to mint a Mac provisioning profile.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Links") {
                linkRow("chevron.left.forwardslash.chevron.right", "GitHub",
                        "https://github.com/deathemperor")
                linkRow("globe", "Website", "https://huuloc.com")
                linkRow("shippingbox", "Project — claude-swap",
                        "https://github.com/deathemperor/claude-swap")
                linkRow("doc.text", "Release notes", changelogURL.absoluteString)
            }

            Section {
                Text("Limitless by deathemperor · MIT License")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .formStyle(.grouped)
        .onAppear { if model.current == nil { Task { await model.check() } } }
    }

    /// The app icon in miniature: ∞ on the midnight→violet gradient
    /// (make-icon.swift is the 1024px source of truth).
    private var appMark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(LinearGradient(
                    colors: [Color(red: 0.42, green: 0.20, blue: 0.95),
                             Color(red: 0.07, green: 0.05, blue: 0.20)],
                    startPoint: .topLeading, endPoint: .bottom))
                .frame(width: 64, height: 64)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.white.opacity(0.15))
                )
                .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
            Text("∞")
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    private func linkRow(_ symbol: String, _ title: String, _ url: String) -> some View {
        Button {
            if let u = URL(string: url) { openURL(u) }
        } label: {
            HStack {
                Image(systemName: symbol)
                    .frame(width: 20)
                    .foregroundStyle(.secondary)
                Text(title)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var changelogURL: URL {
        // Release notes live on the upstream repo (the PyPI package's home).
        if model.updateAvailable, let latest = model.latest {
            return URL(string: "https://github.com/realiti4/claude-swap/releases/tag/v\(latest)")!
        }
        return URL(string: "https://github.com/realiti4/claude-swap/releases")!
    }
}
