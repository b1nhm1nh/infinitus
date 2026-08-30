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

    private static let nightlyAPI = URL(
        string: "https://api.github.com/repos/deathemperor/limitless/releases/tags/nightly")!

    func check(currentVersion: String, nightly: Bool = false) async {
        status = "checking…"
        struct Release: Decodable {
            let tag_name: String
            let html_url: String
            let name: String?
        }
        do {
            var req = URLRequest(url: nightly ? Self.nightlyAPI : Self.api)
            req.setValue("application/vnd.github+json",
                         forHTTPHeaderField: "Accept")
            let (data, resp) = try await URLSession.shared.data(for: req)
            if (resp as? HTTPURLResponse)?.statusCode == 404 {
                status = "no releases published yet — this build came from source"
                return
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            latest = release.tag_name
            if nightly {
                // Rolling tag — no version to compare; show what's current.
                status = "latest: \(release.name ?? "nightly") — reinstall to update"
                return
            }
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

/// Homebrew awareness (user 2026-08-30: "release to homebrew, updates
/// should be from it too"). Channel detection is a Caskroom lookup; the
/// upgrade itself is `brew upgrade/reinstall --cask` — brew swaps the
/// bundle at a new inode, so the running process survives until relaunch.
@MainActor
final class BrewUpdater: ObservableObject {
    enum Channel { case source, stable, nightly }
    @Published var running = false
    @Published var status: String?

    static let brewPath: String? =
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }

    static let channel: Channel = {
        // A dev build (unbundled, or built into the repo) must never
        // read the Caskroom as "this process came from brew" — only the
        // /Applications copy is the cask's.
        guard Bundle.main.bundlePath.hasPrefix("/Applications/"),
              let brew = brewPath else { return .source }
        let caskroom = URL(fileURLWithPath: brew)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Caskroom")
        let fm = FileManager.default
        if fm.fileExists(atPath: caskroom.appendingPathComponent("limitless@nightly").path) {
            return .nightly
        }
        if fm.fileExists(atPath: caskroom.appendingPathComponent("limitless").path) {
            return .stable
        }
        return .source
    }()

    var channelLabel: String {
        switch Self.channel {
        case .source: return "source build"
        case .stable: return "Homebrew"
        case .nightly: return "Homebrew (nightly)"
        }
    }

    /// Uninstall this track's cask, install the other one, relaunch.
    /// The casks conflict_with each other, so the order matters.
    func move(toNightly: Bool) {
        guard !running, let brew = Self.brewPath else { return }
        let fromCask = toNightly ? "limitless" : "limitless@nightly"
        let toCask = toNightly ? "limitless@nightly" : "limitless"
        run(brew: brew, steps: [["uninstall", "--cask", fromCask],
                                ["install", "--cask", toCask]],
            doing: "switching to \(toCask)…")
    }

    /// Runs the brew command, then relaunches into the replaced bundle.
    func upgrade() {
        guard !running, let brew = Self.brewPath else { return }
        let args = Self.channel == .nightly
            ? ["reinstall", "--cask", "limitless@nightly"]
            : ["upgrade", "--cask", "limitless"]
        run(brew: brew, steps: [args], doing: "brew \(args.joined(separator: " "))…")
    }

    private func run(brew: String, steps: [[String]], doing: String) {
        running = true
        status = doing
        Task.detached {
            var ok = true
            var tail = ""
            for args in steps {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: brew)
                p.arguments = args
                let out = Pipe()
                p.standardOutput = out
                p.standardError = out
                try? p.run()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                tail = String(decoding: data, as: UTF8.self)
                    .split(separator: "\n").suffix(2).joined(separator: " · ")
                if p.terminationStatus != 0 { ok = false; break }
            }
            let done = ok
            let detail = tail
            await MainActor.run { [weak self] in
                self?.running = false
                if done {
                    self?.status = "done — relaunching…"
                    let sh = Process()
                    sh.executableURL = URL(fileURLWithPath: "/bin/sh")
                    sh.arguments = ["-c",
                        "sleep 0.8; /usr/bin/open /Applications/Limitless.app"]
                    try? sh.run()
                    NSApplication.shared.terminate(nil)
                } else {
                    self?.status = "brew failed: \(detail)"
                }
            }
        }
    }
}

/// About + updates, CodexBar-style: hero card (icon, version, build,
/// tagline), an Updates group, full-row link rows with leading icons and a
/// trailing arrow, and a license footer.
struct AboutPane: View {
    @ObservedObject var model: UpdateModel
    @StateObject private var appRelease = AppReleaseModel()
    @StateObject private var brew = BrewUpdater()
    @AppStorage("update_channel") private var updateChannel = "stable"
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
                LabeledContent {
                    Button(appRelease.status == nil ? "Check GitHub Releases"
                           : "Recheck") {
                        Task { await appRelease.check(currentVersion: appVersion,
                                                      nightly: updateChannel == "nightly") }
                    }
                } label: {
                    Text("Limitless.app \(appVersion)")
                    if let s = appRelease.status {
                        Text(s).font(.caption).foregroundStyle(.secondary)
                    }
                }
                LabeledContent {
                    if BrewUpdater.channel != .source {
                        Button(BrewUpdater.channel == .nightly
                               ? "Reinstall latest nightly" : "Update via Homebrew") {
                            brew.upgrade()
                        }
                        .disabled(brew.running)
                    }
                } label: {
                    Text("Installed via \(brew.channelLabel)")
                    if let s = brew.status {
                        Text(s).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Picker("Update channel", selection: $updateChannel) {
                    Text("Stable").tag("stable")
                    Text("Nightly").tag("nightly")
                }
                .pickerStyle(.segmented)
                .onChange(of: updateChannel) {
                    Task { await appRelease.check(currentVersion: appVersion,
                                                  nightly: updateChannel == "nightly") }
                }
                if BrewUpdater.channel == .stable, updateChannel == "nightly" {
                    Button("Switch the install to the nightly track") {
                        brew.move(toNightly: true)
                    }
                    .disabled(brew.running)
                } else if BrewUpdater.channel == .nightly, updateChannel == "stable" {
                    Button("Switch the install back to stable") {
                        brew.move(toNightly: false)
                    }
                    .disabled(brew.running)
                } else if BrewUpdater.channel == .source {
                    Text("Source builds only use the channel for the release "
                         + "check; the brew tracks are limitless and "
                         + "limitless@nightly.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("App releases ship through Homebrew "
                     + "(brew install --cask deathemperor/tap/limitless — "
                     + "@nightly for the daily channel) and GitHub releases; "
                     + "building from source is the developer path. Engine "
                     + "updates moved to Engines → cswap.")
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
