import SwiftUI
import AppKit
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
    @Published var autoInstall: Bool { didSet {
        defaults.set(autoInstall, forKey: "update_auto_install")
        // Flipping install ON with an update already found must act now,
        // not at tomorrow's scheduled check ("still no engine auto
        // update?" — user, 2026-08-30).
        if autoInstall, updateAvailable { Task { await upgrade() } }
    } }

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
            } else if a > b {
                // The dev case on this machine: a uv tool install --from
                // the local checkout outruns PyPI — auto-update is idle
                // because there is genuinely nothing newer to install.
                status = "up to date — local \(cur) is ahead of PyPI \(fetched)"
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

/// The app's own release channel (user "make it so", 2026-08-30):
/// GitHub releases on deathemperor/limitless. Until the repo is pushed
/// and a release exists the check reports "no releases yet" — the
/// machinery is live, the feed is what's pending. Developers keep
/// building from source; releases are the distribution path.
@MainActor
final class AppReleaseModel: ObservableObject {
    @Published var latest: String?
    @Published var status: String?
    private static let api = URL(
        string: "https://api.github.com/repos/deathemperor/limitless/releases/latest")!

    func check(currentVersion: String) async {
        status = "checking…"
        struct Release: Decodable {
            let tag_name: String
            let html_url: String
        }
        do {
            var req = URLRequest(url: Self.api)
            req.setValue("application/vnd.github+json",
                         forHTTPHeaderField: "Accept")
            let (data, resp) = try await URLSession.shared.data(for: req)
            if (resp as? HTTPURLResponse)?.statusCode == 404 {
                status = "no releases published yet — this build came from source"
                return
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            latest = release.tag_name
            let tag = release.tag_name.hasPrefix("v")
                ? String(release.tag_name.dropFirst()) : release.tag_name
            if let a = PackageVersion(currentVersion), let b = PackageVersion(tag),
               a < b {
                status = "\(release.tag_name) is available on GitHub"
            } else {
                status = "up to date (latest release: \(release.tag_name))"
            }
        } catch {
            status = "release check failed: \(error.localizedDescription)"
        }
    }
}

/// About + updates, CodexBar-style: hero card (icon, version, build,
/// tagline), an Updates group, full-row link rows with leading icons and a
/// trailing arrow, and a license footer.
struct AboutPane: View {
    @ObservedObject var model: UpdateModel
    @StateObject private var appRelease = AppReleaseModel()
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
                // One switch for the whole pipeline (user request
                // 2026-08-30); the two prefs stay separate underneath so
                // sync/rollback keep their meaning.
                Toggle("Update automatically", isOn: Binding(
                    get: { model.autoCheck && model.autoInstall },
                    set: { model.autoCheck = $0; model.autoInstall = $0 }))
                    .help("Watch PyPI daily; when a newer claude-swap "
                          + "appears, run `cswap upgrade` unattended and "
                          + "restart the engine.")
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
                Divider()
                LabeledContent {
                    Button(appRelease.status == nil ? "Check GitHub Releases"
                           : "Recheck") {
                        Task { await appRelease.check(currentVersion: appVersion) }
                    }
                } label: {
                    Text("Limitless.app \(appVersion)")
                    if let s = appRelease.status {
                        Text(s).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Engine updates come from PyPI; app releases come "
                     + "from GitHub (deathemperor/limitless). Building "
                     + "from source is the developer path.")
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
                linkRow("shippingbox", "Project — Limitless",
                        "https://github.com/deathemperor/limitless")
                linkRow("gearshape.2", "Engine — claude-swap",
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

    /// The real Limitless icon EVERYWHERE (user 2026-08-30): bundled runs
    /// have it as the app icon; unbundled runs (run-unbundled.sh) pull it
    /// from the built Limitless.app on disk (bundle id lookup, then the
    /// repo's known path). The glyph-on-gradient card remains only as the
    /// final fallback when no built bundle exists at all.
    @ViewBuilder private var appMark: some View {
        if let icon = Self.limitlessIcon {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 64, height: 64)
                .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
        } else {
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
                Image(nsImage: MenuBarGlyph.image)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 38, height: 38)
                    .foregroundStyle(.white)
            }
        }
    }

    static var limitlessIcon: NSImage? {
        if Bundle.main.bundlePath.hasSuffix(".app"),
           let icon = NSApp.applicationIconImage {
            return icon
        }
        var candidates = [FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("death/limitless/Limitless.app").path]
        if let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.huuloc.limitless") {
            candidates.insert(url.path, at: 0)
        }
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            let icon = NSWorkspace.shared.icon(forFile: path)
            icon.size = NSSize(width: 64, height: 64)
            return icon
        }
        return nil
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
