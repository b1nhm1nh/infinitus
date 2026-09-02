import Foundation
import SwiftUI
import AppKit
import CswapCore
import InfinitusUI

/// Main-actor state the MenuBarExtra renders. Feeds per spec §2:
/// snapshots from `cswap list --json` (timer + right after any switch
/// event), events from the supervised `cswap auto --json`.
@MainActor
final class AppModel: ObservableObject {
    @Published var accounts: [Account] = []
    @Published var activeNumber: Int?
    @Published var nextCandidate: Int?
    /// Limit-stopped sessions waiting to resume; non-nil only while
    /// every account is at a limit (rides the all-limited banner).
    @Published var waitingResume: Int?
    private var waitingScanAt: Date = .distantPast
    @Published var nextRecovery: NextRecovery?
    @Published var liveSessions: LiveSessions?
    /// Session-list popover (brain chip click) — popup-wide state so the
    /// wide chip and the rail badge share one popover.
    @Published var sessionsShown = false
    // Animation triggers. switchFlashTick fires the celebration sweep on
    // the (new) active row; dataPulseTick ripples the sync dot whenever a
    // snapshot actually changed something visible.
    @Published var switchFlashTick = 0
    /// Per-account death beats: bumped when a row flips alive -> dead
    /// in a snapshot (the celebration's mirror, user 2026-08-30).
    @Published var deathTicks: [Int: Int] = [:]
    /// Rows currently DYING: dead in the data, but still rendered with
    /// their gauges for a beat so the killing-blow drama (drop plunge,
    /// shard finisher, death beat) plays out — the dead layout swap
    /// unmounted the bar instantly ("killed instantly", user
    /// 2026-08-31). Cleared a few seconds after each death.
    @Published var dying: Set<Int> = []
    /// Revival fanfares: bumped when a row flips dead -> alive (its
    /// window reset while drained) — the dramatic full-line glow
    /// (user 2026-08-31).
    @Published var reviveTicks: [Int: Int] = [:]
    /// Click-to-switch staging: the row sets this, the popup's
    /// confirmation alert commits or clears it.
    @Published var pendingSwitch: Int?
    @Published var dataPulseTick = 0
    /// Debug-only (defaults write … debug_menu -bool true): adds the
    /// Animations tab so every effect can be fired by hand.
    let debugMenu = UserDefaults.standard.bool(forKey: "debug_menu")
    @Published var engineState: EngineSupervisor.State = .stopped
    struct EventEntry: Identifiable {
        let id = UUID()
        let at = Date()
        let icon: String
        let text: String
    }
    @Published var eventLog: [EventEntry] = []
    /// App-side resume nudges + /rc re-arm (ResumeService.swift).
    let resume = ResumeService()
    /// Sessions popover's mini progress rows (SessionProgressModel.swift).
    let sessionProgress = SessionProgressModel()
    @Published var lastError: String?

    let cli: CswapCLI?
    /// True for the Animation Playground's private model: cli is pinned
    /// to the bundled demo script and every outward side effect —
    /// snapshot cache, notifications, resume nudges, push, sync, power
    /// assertions, the engine supervisor — is suppressed, so nothing it
    /// does can touch real accounts or real sessions (user 2026-08-31).
    let isPlayground: Bool
    /// Set by StatusItemHolder — opens the controller-owned Settings window
    /// (the SwiftUI Settings scene is unreachable from popover hosts).
    var showSettings: (() -> Void)?
    /// Set by StatusItemHolder — closes and re-shows an open popover.
    /// NSPopover keeps a stale fitting size when the content swaps shape
    /// wholesale (wide<->stacked left it clipped or oversized until a
    /// manual reopen, user-verified); a programmatic bounce is that same
    /// fix without the user doing it.
    var reopenPopover: (() -> Void)?
    /// Set by StatusItemHolder — closes the popover and opens the same
    /// content as a free-floating window (the pop-out action).
    var popOut: (() -> Void)?
    /// Set by StatusItemHolder — toggles the full-screen fleet wall
    /// (issue #11).
    var showWall: (() -> Void)?
    // The bundle on disk was rebuilt since this instance launched (the
    // dev loop, or a manual make-app.sh) — surfaced as "restart to update".
    @Published var appUpdatePending = false
    /// A newer Infinitus release than this build (About → Updates does
    /// the check; the popup chip just points there).
    @Published var appUpdateVersion: String?
    private let launchExecutableDate = AppModel.executableDate()
    private var supervisor: EngineSupervisor?
    private var refreshTask: Task<Void, Never>?
    private var lastNotifiedActive: Int?

    // Display prefs, persisted to UserDefaults under the same names and
    // defaults as the rumps MenuBarSettings. @Published (not @AppStorage):
    // @AppStorage inside an ObservableObject never fires objectWillChange,
    // so the MenuBarExtra title would go stale.
    @Published var showAccountName: Bool { didSet { defaults.set(showAccountName, forKey: "show_account_name") } }
    @Published var titlePct: String { didSet { defaults.set(titlePct, forKey: "title_pct") } }
    @Published var titleScoped: Bool { didSet { defaults.set(titleScoped, forKey: "title_scoped") } }
    // Menu bar percentages count remaining instead of used (todo
    // 2026-08-30). Menu-bar-only: the popup gauges stay HP-style.
    @Published var titleRemaining: Bool { didSet { defaults.set(titleRemaining, forKey: "title_remaining") } }
    /// Icon only in the menu bar — no name, no percentages (user
    /// 2026-08-30). Display-time override; the individual title prefs
    /// keep their values for when this flips back off.
    @Published var titleIconOnly: Bool { didSet { defaults.set(titleIconOnly, forKey: "title_icon_only") } }
    @Published var refreshInterval: Int { didSet { defaults.set(refreshInterval, forKey: "refresh_interval") } }
    @Published var gamification: String { didSet { defaults.set(gamification, forKey: "gamification_style") } }
    @Published var compactRows: Bool { didSet { defaults.set(compactRows, forKey: "compact_rows") } }
    // Hide the popup's action controls but keep the status chips (claude
    // status, working sessions, engine badge) — todo 2026-08-30. Safe to
    // persist: every hidden action lives in the status item's right-click
    // menu, so Settings/Quit can never strand.
    @Published var footerActionsHidden: Bool { didSet { defaults.set(footerActionsHidden, forKey: "footer_actions_hidden") } }
    @Published var popupLayout: String { didSet { defaults.set(popupLayout, forKey: "popup_layout") } }
    @Published var popupTextSize: String { didSet { defaults.set(popupTextSize, forKey: "popup_text_size") } }
    // Popup transparency, 0 (full frost) … 1 (clearest). ONE dial for
    // every focus state: the backdrop-blur glass renders identically
    // everywhere, and a per-focus value made the popup visibly jump as
    // key state flapped (user 2026-08-30: "another state that randomly
    // transition"). Key name kept for existing prefs.
    @Published var glassFocused: Double { didSet { defaults.set(glassFocused, forKey: "glass_focused") } }
    /// Content-fill scale for the transparency dial. Once the chrome
    /// went pure at max (measured: body gaps match the backdrop's
    /// luminance), the card/band fills were what still blocked the
    /// backdrop (user 2026-08-30: "max transparency doesn't make glass
    /// transparency that much") — so they thin with the dial too.
    var fillScale: Double { 1 - 0.6 * glassFocused }
    // Launch-intro choreography (dev-tunable, 2026-08-30): content
    // entrance style, overall speed multiplier, title flourish variant.
    // introTick replays the whole intro on demand.
    @Published var introTick = 0
    @Published var introStyle: String { didSet { defaults.set(introStyle, forKey: "intro_style") } }
    @Published var introSpeed: Double { didSet { defaults.set(introSpeed, forKey: "intro_speed") } }
    @Published var introTitle: String { didSet { defaults.set(introTitle, forKey: "intro_title") } }
    /// Pace fire on 7d/model bars ("off"/"ember"/"flame"/"limit").
    @Published var burnStyle: String { didSet { defaults.set(burnStyle, forKey: "burn_style") } }
    /// Mock mode (user 2026-08-31): the bundled demo fleet stands in
    /// for the engine. Machine-local, deliberately never synced. cli
    /// is a let, so flipping this relaunches — the restart IS the
    /// re-detect (installEngine precedent).
    @Published var mockMode: Bool {
        didSet {
            defaults.set(mockMode, forKey: "mock_mode")
            relaunchApp()
        }
    }

    /// Intro phase timing: bars (and the active-row flash) hold until
    /// the content entrance has fully landed (user 2026-08-30: "only
    /// when content in full display -> play bar fills + flash").
    var introContentDuration: Double { 0.7 / max(0.2, introSpeed) }
    var introBarDelay: Double { introContentDuration + 0.25 }

    /// The debug pane's Replay: the WHOLE sequence, not just the
    /// entrances — bars replay via the introTick environment, and the
    /// flash fires after the fill starts.
    func replayIntro() {
        introTick += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + introBarDelay + 0.5) {
            self.switchFlashTick += 1
        }
    }
    // Deliberately NOT persisted: if a hidden icon survived a relaunch there
    // would be no UI left to unhide it from (the Settings window is only
    // reachable through the popup). Hiding lasts until quit.
    @Published var menuBarIconShown = true
    // Pin holds the popover open (click-outside stops closing it).
    // Persisted by request — a pinned popup stays pinned across relaunches.
    @Published var popoverPinned: Bool { didSet { defaults.set(popoverPinned, forKey: "popover_pinned") } }
    /// Hold a power assertion while any session is mid-turn (KeepAwake).
    /// Keep the fleet sorted (most headroom first) through `cswap reorder`
    /// after every snapshot — see CswapCore.AutoOrder for the policy.
    /// Display-only: rows sorted most-headroom-first with the active
    /// account and the next candidate pinned on top (todo 2026-09-01).
    /// Engine slots never move — unlike autoOrder, nothing is written.
    @Published var sortByHeadroom: Bool {
        didSet { defaults.set(sortByHeadroom, forKey: "sort_headroom") }
    }
    @Published var autoOrder: Bool {
        didSet {
            defaults.set(autoOrder, forKey: "auto_order")
            if autoOrder { applyAutoOrder() }
        }
    }
    @Published var keepAwake: Bool {
        didSet {
            defaults.set(keepAwake, forKey: "keep_awake")
            awake.update(wanted: keepAwake, busyCount: liveSessions?.busy ?? 0)
        }
    }
    // Away-push triggers beyond switches (PushTriggers has the rules).
    @Published var pushSessionsDone: Bool { didSet { defaults.set(pushSessionsDone, forKey: "push_sessions_done") } }
    @Published var pushAllDead: Bool { didSet { defaults.set(pushAllDead, forKey: "push_all_dead") } }
    @Published var pushLastAlive: Bool { didSet { defaults.set(pushLastAlive, forKey: "push_last_alive") } }
    let sync = SettingsSyncModel()
    let historyRecorder = UsageHistoryRecorder()
    let mirrorExporter = MirrorExporter()
    private let awake = KeepAwake()
    private var pushTriggers = PushTriggers()
    private let defaults: UserDefaults
    static let playgroundSuite = "com.huuloc.limitless.playground"

    /// Custom skins from themes.json, loaded at launch and on demand
    /// (the Display pane reloads when it appears).
    @Published var customThemes: [RowTheme] = RowTheme.loadCustom()
    var availableThemes: [RowTheme] { RowTheme.builtins + customThemes }
    var rowTheme: RowTheme {
        availableThemes.first { $0.id == gamification } ?? .off
    }
    func reloadCustomThemes() { customThemes = RowTheme.loadCustom() }

    /// Popup scale factor — applied as a measured scaleEffect (macOS has
    /// no Dynamic Type; see PopupScale).
    var popupScale: CGFloat {
        switch popupTextSize {
        case "large": return 1.15
        case "xlarge": return 1.3
        case "huge": return 1.5
        default: return 1
        }
    }

    var title: String {
        if titleIconOnly { return "" }
        return TitleFormatter.format(
            account: accounts.first(where: { $0.active }),
            prefs: TitlePrefs(showAccountName: showAccountName,
                              titlePct: titlePct, titleScoped: titleScoped,
                              titleRemaining: titleRemaining),
            icon: "")  // the status button wears MenuBarGlyph instead
    }

    /// One-time prefs adoption from the pre-2026-08-30 bundle id
    /// (io.github.claude-swap.CswapBar.g2). Bundled runs only — the
    /// unbundled domain is per-executable name and unaffected. Copies,
    /// never moves: the old domain stays for rollback. Locally-set keys win.
    private static func migrateLegacyDefaults() {
        let std = UserDefaults.standard
        guard !std.bool(forKey: "migrated_from_g2"),
              let legacy = std.persistentDomain(
                forName: "io.github.claude-swap.CswapBar.g2") else { return }
        for (key, value) in legacy where std.object(forKey: key) == nil {
            std.set(value, forKey: key)
        }
        std.set(true, forKey: "migrated_from_g2")
    }

    init(playground: Bool = false) {
        isPlayground = playground
        // Playground prefs sandbox: reads SEED from the user's live
        // settings (registration domain, volatile), writes land in a
        // private suite that now PERSISTS across launches (user
        // 2026-08-31: "persist playground state with selected
        // changes") — still never touching real prefs. Reset wipes the
        // suite back to the live-settings seed.
        if playground {
            let d = UserDefaults(suiteName: Self.playgroundSuite)!
            d.register(defaults: UserDefaults.standard.dictionaryRepresentation())
            defaults = d
        } else {
            defaults = UserDefaults.standard
        }
        Self.migrateLegacyDefaults()
        showAccountName = defaults.object(forKey: "show_account_name") as? Bool ?? true
        let pct = defaults.string(forKey: "title_pct") ?? "both"
        titlePct = TitlePrefs.pctChoices.contains(pct) ? pct : "both"
        titleScoped = defaults.object(forKey: "title_scoped") as? Bool ?? false
        let interval = defaults.object(forKey: "refresh_interval") as? Int ?? 60
        refreshInterval = TitlePrefs.refreshChoices.contains(interval) ? interval : 60
        // Any string is allowed — resolution falls back to the plain theme
        // when the id names neither a built-in nor a custom theme.
        gamification = defaults.string(forKey: "gamification_style")
            ?? ((defaults.object(forKey: "gamified_rows") as? Bool ?? false) ? "rpg" : "off")
        compactRows = defaults.object(forKey: "compact_rows") as? Bool ?? false
        footerActionsHidden = defaults.object(forKey: "footer_actions_hidden") as? Bool ?? false
        titleRemaining = defaults.object(forKey: "title_remaining") as? Bool ?? false
        titleIconOnly = defaults.object(forKey: "title_icon_only") as? Bool ?? false
        popoverPinned = defaults.object(forKey: "popover_pinned") as? Bool ?? false
        popupLayout = defaults.string(forKey: "popup_layout") ?? "wide"
        popupTextSize = defaults.string(forKey: "popup_text_size") ?? "default"
        glassFocused = defaults.object(forKey: "glass_focused") as? Double ?? 0.7
        introStyle = defaults.string(forKey: "intro_style") ?? "top"
        introSpeed = defaults.object(forKey: "intro_speed") as? Double ?? 1.0
        introTitle = defaults.string(forKey: "intro_title") ?? "zoom"
        burnStyle = defaults.string(forKey: "burn_style") ?? "ember"
        // Local: init reads it again below before every stored
        // property is set (two-phase init forbids self.mockMode there).
        let mock = defaults.object(forKey: "mock_mode") as? Bool ?? false
        mockMode = mock
        keepAwake = defaults.object(forKey: "keep_awake") as? Bool ?? false
        autoOrder = defaults.object(forKey: "auto_order") as? Bool ?? false
        sortByHeadroom = defaults.object(forKey: "sort_headroom") as? Bool ?? true
        // Push triggers default ON — they exist because they were asked for.
        pushSessionsDone = defaults.object(forKey: "push_sessions_done") as? Bool ?? true
        pushAllDead = defaults.object(forKey: "push_all_dead") as? Bool ?? true
        pushLastAlive = defaults.object(forKey: "push_last_alive") as? Bool ?? true
        if playground {
            // Isolation is the contract: no demo script, no data at all
            // (never fall back to the real engine here).
            if let demo = Self.demoScriptPath() {
                cli = CswapCLI(binaryPath: demo)
            } else {
                cli = nil
                lastError = "demo script missing — playground has no data"
            }
        } else if mock, let demo = Self.demoScriptPath() {
            cli = CswapCLI(binaryPath: demo)
        } else if let path = CswapLocator.locate() {
            cli = CswapCLI(binaryPath: path)
            if mock {
                lastError = "demo script missing — running the real engine"
            }
        } else {
            cli = nil
            lastError = "cswap not found — install it (uv tool install claude-swap)"
        }
        if !playground { sync.attach(model: self) }
        // Last run's snapshot renders NOW — the popup otherwise opened
        // as an empty sliver and expanded seconds later when the first
        // `cswap list` returned, eating the intro (user 2026-08-30).
        // Live values roll in over it via the numeric transitions.
        if !playground,
           let data = try? Data(contentsOf: Self.snapshotCacheURL),
           let cached = try? JSONDecoder().decode(AccountList.self, from: data) {
            accounts = cached.accounts
            activeNumber = cached.activeAccountNumber
            nextCandidate = cached.nextCandidate
            nextRecovery = RecoveryMath.corrected(engine: cached.nextRecovery, accounts: cached.accounts)
            liveSessions = cached.liveSessions
        }
    }

    /// App-side cache of our own subprocess output (never an engine
    /// internal file).
    static let snapshotCacheURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("Infinitus/snapshot-cache.json")
    }()

    /// The popup just opened with data already on screen (cache or an
    /// earlier snapshot): play the launch flash on the same clock the
    /// data-landing path uses. No-op while empty — that case is handled
    /// by firstLoad in refreshSnapshot.
    func introOpened() {
        guard !accounts.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + introBarDelay + 0.5) {
            self.switchFlashTick += 1
        }
    }

    /// Re-read the persisted display prefs after an iCloud sync pull — the
    /// @Published values were initialized once at launch and would
    /// otherwise never see the imported defaults.
    func reloadPrefs() {
        showAccountName = defaults.object(forKey: "show_account_name") as? Bool ?? true
        let pct = defaults.string(forKey: "title_pct") ?? "both"
        titlePct = TitlePrefs.pctChoices.contains(pct) ? pct : "both"
        titleScoped = defaults.object(forKey: "title_scoped") as? Bool ?? false
        let interval = defaults.object(forKey: "refresh_interval") as? Int ?? 60
        refreshInterval = TitlePrefs.refreshChoices.contains(interval) ? interval : 60
        gamification = defaults.string(forKey: "gamification_style") ?? "off"
        compactRows = defaults.object(forKey: "compact_rows") as? Bool ?? false
        footerActionsHidden = defaults.object(forKey: "footer_actions_hidden") as? Bool ?? false
        titleRemaining = defaults.object(forKey: "title_remaining") as? Bool ?? false
        titleIconOnly = defaults.object(forKey: "title_icon_only") as? Bool ?? false
        popupLayout = defaults.string(forKey: "popup_layout") ?? "wide"
        popupTextSize = defaults.string(forKey: "popup_text_size") ?? "default"
        glassFocused = defaults.object(forKey: "glass_focused") as? Double ?? 0.7
        keepAwake = defaults.object(forKey: "keep_awake") as? Bool ?? false
        autoOrder = defaults.object(forKey: "auto_order") as? Bool ?? false
        sortByHeadroom = defaults.object(forKey: "sort_headroom") as? Bool ?? true
        pushSessionsDone = defaults.object(forKey: "push_sessions_done") as? Bool ?? true
        pushAllDead = defaults.object(forKey: "push_all_dead") as? Bool ?? true
        pushLastAlive = defaults.object(forKey: "push_last_alive") as? Bool ?? true
    }

    /// Playground reset (user 2026-08-31): wipe the sandbox suite so
    /// every knob falls back to the registration seed — the user's
    /// live settings — then re-read. Playground models only.
    func resetPlaygroundPrefs() {
        guard isPlayground else { return }
        defaults.removePersistentDomain(forName: Self.playgroundSuite)
        reloadPrefs()
        introStyle = defaults.string(forKey: "intro_style") ?? "top"
        introSpeed = defaults.object(forKey: "intro_speed") as? Double ?? 1.0
        introTitle = defaults.string(forKey: "intro_title") ?? "zoom"
        burnStyle = defaults.string(forKey: "burn_style") ?? "ember"
    }

    /// Idempotent: called from app init so the supervised engine starts at
    /// LAUNCH — a window-style MenuBarExtra may not build its content view
    /// until the first click, and rumps started its engine immediately.
    func startFeeds() {
        detectOnboarding()
        resume.log = { [weak self] icon, text in
            guard let self else { return }
            self.eventLog.append(EventEntry(icon: icon, text: text))
            if self.eventLog.count > 100 { self.eventLog.removeFirst(self.eventLog.count - 100) }
        }
        guard let cli, supervisor == nil else { return }
        if !isPlayground { startEngine(binary: cli.binaryPath) }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshSnapshot()
                // Read the pref each pass so an interval change applies on
                // the next tick without restarting the task.
                let seconds = await MainActor.run { self?.refreshInterval ?? 60 }
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            }
        }
    }

    private func startEngine(binary: String) {
        let supervisor = EngineSupervisor(
            binaryPath: binary,
            onLine: { [weak self] line in
                Task { @MainActor in self?.consume(line) }
            },
            onState: { [weak self] state in
                Task { @MainActor in self?.engineState = state }
            }
        )
        self.supervisor = supervisor
        Task { await supervisor.start() }
    }

    private func consume(_ line: EventLine) {
        switch line {
        case .event(let event):
            eventLog.append(EventEntry(icon: event.icon, text: event.summary))
            if eventLog.count > 100 { eventLog.removeFirst(eventLog.count - 100) }
            switch event.kind {
            case "switch":
                Task { await refreshSnapshot() }  // the snapshot diff posts the notification
            case "session-resumed":
                Notifier.post(title: "claude-swap", body: event.summary)
            case "remote-control-rearmed":
                Notifier.post(title: "claude-swap", body: event.summary)
            case "account-unquarantined":
                Notifier.post(title: "claude-swap", body: "account back in rotation")
            case "all-exhausted":
                Notifier.post(title: "claude-swap", body: "every account is at its limit")
            default:
                break
            }
        case .schemaMismatch(let version):
            engineState = .schemaMismatch(version)
        case .garbage:
            break  // logged upstream; never fatal (spec §2)
        }
    }

    private static func executableDate() -> Date? {
        guard let url = Bundle.main.executableURL else { return nil }
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
    }

    /// Stop the engine cleanly, then relaunch this app from its bundle —
    /// the "restart to update" action after an on-disk rebuild.
    // MARK: onboarding — engine install (todo 2026-08-30)

    /// The bundled demo engine (tools/demo-cswap -> Resources), a tiny
    /// fabricated-fleet cswap. Unbundled dev runs look next to the
    /// executable instead (run-unbundled.sh copies it there).
    static func demoScriptPath() -> String? {
        if let p = Bundle.main.path(forResource: "demo-cswap", ofType: nil),
           FileManager.default.isExecutableFile(atPath: p) { return p }
        if let dir = (Bundle.main.executablePath as NSString?)?
            .deletingLastPathComponent {
            let p = dir + "/demo-cswap"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Playground-only: pretend no engine was found, so the onboarding
    /// card is reachable without an env-var relaunch (issue #6).
    @Published var simulateNoEngine = false
    /// True when no cswap binary was found at launch; the popup swaps
    /// its rows for the onboarding card.
    var engineMissing: Bool { cli == nil || simulateNoEngine }

    // MARK: onboarding — machine detection (todo 2026-09-01)

    @Published var claudeCLI: ClaudeCLIInfo?
    @Published var cliProxy: CLIProxyInfo?
    /// Something answered on the management port while the auth dir
    /// exists — the proxy is probably running right now.
    @Published var cliProxyLive = false
    @Published var addingFirstAccount = false
    @Published var firstAccountMessage: String?
    /// Set once a real snapshot decoded — gates the "no accounts" card
    /// so it can't flash during the first refresh.
    @Published var snapshotLoaded = false

    func detectOnboarding() {
        Task.detached(priority: .utility) { [weak self] in
            let claude = ClaudeCLIDetect.info()
            let proxy = CLIProxyDetect.info()
            let live: Bool
            if proxy != nil {
                var req = URLRequest(
                    url: URL(string: "http://127.0.0.1:\(CLIProxyDetect.defaultPort)/")!)
                req.timeoutInterval = 0.8
                // ANY HTTP answer counts — management routes 404 without a
                // secret key, the point is that something is listening.
                live = (try? await URLSession.shared.data(for: req)) != nil
            } else {
                live = false
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.claudeCLI = claude.isPresent ? claude : nil
                self.cliProxy = proxy
                self.cliProxyLive = live
            }
        }
    }

    /// `cswap add` registers whichever account Claude Code is signed in
    /// as — the "adopt the current login" onboarding path.
    func addFirstAccount() {
        guard let cli, !addingFirstAccount else { return }
        addingFirstAccount = true
        firstAccountMessage = nil
        Task {
            do {
                _ = try await cli.run(["add"])
                await refreshSnapshot()
            } catch {
                firstAccountMessage = (error as? CLIError)?.message ?? "\(error)"
            }
            addingFirstAccount = false
        }
    }
    @Published var installingEngine = false
    @Published var installMessage: String?

    /// Button-triggered only — never auto-installs. Runs
    /// `uv tool install claude-swap`, then relaunches so init re-runs
    /// the locator (cli stays a let; the restart IS the re-detect).
    func installEngine() {
        guard !installingEngine else { return }
        let uv = CswapLocator.locate(candidates: [
            "\(NSHomeDirectory())/.local/bin/uv",
            "/opt/homebrew/bin/uv",
            "/usr/local/bin/uv",
        ])
        guard let uv else {
            installMessage = "uv not found — get it first: brew install uv"
            return
        }
        installingEngine = true
        installMessage = "Installing claude-swap…"
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: uv)
            p.arguments = ["tool", "install", "claude-swap"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            do {
                try p.run()
                p.waitUntilExit()
                let out = String(decoding:
                    pipe.fileHandleForReading.readDataToEndOfFile(),
                    as: UTF8.self)
                let ok = p.terminationStatus == 0
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.installingEngine = false
                    if ok {
                        self.installMessage = "Installed — restarting…"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            self.relaunchApp()
                        }
                    } else {
                        self.installMessage = "Install failed: "
                            + out.suffix(200)
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.installingEngine = false
                    self?.installMessage = "Couldn't run uv: \(error.localizedDescription)"
                }
            }
        }
    }

    func relaunchApp() {
        let bundle = Bundle.main.bundleURL.path
        let old = supervisor
        supervisor = nil
        Task {
            await old?.stop()
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            // Unbundled dev runs are a bare executable — `open` on its
            // directory would just raise Finder.
            let exe = Bundle.main.executablePath ?? ""
            let cmd = bundle.hasSuffix(".app")
                ? "sleep 0.8; /usr/bin/open \"\(bundle)\""
                : "sleep 0.8; exec \"\(exe)\""
            p.arguments = ["-c", cmd]
            try? p.run()
            await MainActor.run { NSApplication.shared.terminate(nil) }
        }
    }

    func refreshSnapshot() async {
        guard let cli else { return }
        do {
            let (list, raw) = try await cli.accountListRaw()
            if !isPlayground {
                try? FileManager.default.createDirectory(
                    at: Self.snapshotCacheURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try? raw.write(to: Self.snapshotCacheURL, options: .atomic)
            }
            let previous = activeNumber
            // withAnimation: the pct texts carry .contentTransition(.numericText)
            // so a fresh snapshot rolls the digits (the token-burn feel)
            // instead of snapping them.
            let changed = !accountsVisuallyEqual(accounts, list.accounts)
            let previousActive = activeNumber
            let firstLoad = accounts.isEmpty && !list.accounts.isEmpty
            // alive -> dead diff BEFORE the state swap. First load has no
            // previous state, so nothing fires on launch by construction.
            let wasAlive = Set(accounts.filter {
                !AccountVitals.isDead($0.usage) }.map(\.number))
            let newlyDead = list.accounts.filter {
                AccountVitals.isDead($0.usage) && wasAlive.contains($0.number)
            }.map(\.number)
            let wasDead = Set(accounts.filter {
                AccountVitals.isDead($0.usage) }.map(\.number))
            let newlyAlive = list.accounts.filter {
                !AccountVitals.isDead($0.usage) && wasDead.contains($0.number)
            }.map(\.number)
            snapshotLoaded = true
            withAnimation(.easeInOut(duration: 0.6)) {
                accounts = list.accounts
                activeNumber = list.activeAccountNumber
                nextCandidate = list.nextCandidate
                nextRecovery = RecoveryMath.corrected(engine: list.nextRecovery, accounts: list.accounts)
                liveSessions = list.liveSessions
            }
            if let now = list.activeAccountNumber, let previousActive,
               previousActive != now {
                switchFlashTick += 1
            }
            // Utilization history (todo 2026-09-01): every real snapshot
            // feeds the per-machine JSONL; the playground's fabricated
            // fleet must never pollute it.
            if !isPlayground {
                let accts = list.accounts
                let syncOn = sync.enabled
                Task.detached(priority: .utility) { [historyRecorder] in
                    await historyRecorder.record(accounts: accts, syncEnabled: syncOn)
                }
                // Fleet mirror (#9 phase 1): lets the mobile companion see
                // this machine's last snapshot. Throttled inside the actor.
                // Prefs (#9 phase C1: "Follow Mac") captured here on the
                // main actor since AppModel's published properties aren't
                // Sendable-safe to read from the detached task.
                let prefs = FleetPrefs(
                    themeID: gamification, compactRows: compactRows,
                    popupLayout: popupLayout, burnStyle: burnStyle,
                    introStyle: introStyle, introTitle: introTitle,
                    introSpeed: introSpeed, customThemes: customThemes)
                Task.detached(priority: .utility) { [mirrorExporter] in
                    await mirrorExporter.record(listJSON: raw, prefs: prefs)
                }
            }
            // All-limited: count the limit-stopped sessions waiting to be
            // resumed (todo 2026-09-01), reusing the resume mechanism's
            // own detection — Claude Code's files, never engine internals.
            // Throttled: the transcript tails re-read at most every 20s.
            if list.nextCandidate == nil, list.nextRecovery != nil {
                if Date().timeIntervalSince(waitingScanAt) > 20 {
                    waitingScanAt = Date()
                    Task.detached(priority: .utility) { [weak self] in
                        let dir = ClaudeSessions.configHome()
                        let stopped = Transcript.findStopped(
                            sessions: ClaudeSessions.list(claudeDir: dir),
                            claudeDir: dir)
                        let count = stopped.count
                        await MainActor.run { [weak self] in
                            self?.waitingResume = count
                        }
                    }
                }
            } else {
                waitingResume = nil
            }
            // The death sequence (user 2026-08-31: kill animation for
            // the last drop of any kind, "still play dead animation
            // after"): the row keeps its gauges while the killing
            // drop plays (plunge 0-1.5s, shards+shake ~1.5-2.4s), the
            // death beat lands AFTER the finisher, and only then does
            // the layout flip to the dead presentation.
            for n in newlyDead {
                dying.insert(n)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.3) {
                    self.deathTicks[n, default: 0] += 1
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.9) {
                    self.dying.remove(n)
                    // The dead row keeps its place (and its skull is
                    // held back) until the tragedy finishes; only now
                    // does auto-order move it down (user 2026-08-31:
                    // "delay moving the account until dead plays").
                    withAnimation(.easeInOut(duration: 0.5)) {
                        self.applyAutoOrder()
                    }
                }
            }
            for n in newlyAlive { reviveTicks[n, default: 0] += 1 }
            // Launch greeting: once the first snapshot renders, the
            // active row plays its sweep alongside the bars' fill-up
            // (user 2026-08-30). Delayed so the popup has drawn.
            // First snapshot = the intro's single clock: every entrance,
            // the bars, the flash, and the title all key off this tick,
            // so the sequence is identical run to run (title timing
            // drifted when it ran from view-mount instead).
            if firstLoad {
                DispatchQueue.main.async { self.replayIntro() }
            }
            if changed { dataPulseTick += 1 }
            lastError = nil
            // Piggyback on the refresh tick: one cheap stat per pass.
            if !appUpdatePending, let launched = launchExecutableDate,
               let now = Self.executableDate(),
               now > launched.addingTimeInterval(1) {
                appUpdatePending = true
            }
            // Switch notifications come from this DISPLAY-feed diff, not the
            // engine's `switch` events: our engine is parked whenever another
            // host (rumps, cswap watch, cswap auto) holds the mutex, and a
            // parked engine sees no events — the 2026-08-28 silent-switch
            // bug. The diff sees every switch regardless of who executed it,
            // manual ones included.
            if !isPlayground, let current = list.activeAccountNumber,
               let previous, previous != current, lastNotifiedActive != current {
                lastNotifiedActive = current
                let name = accounts.first(where: { $0.number == current })
                    .map { $0.alias ?? String($0.email.prefix(while: { $0 != "@" })) } ?? "#\(current)"
                Notifier.post(title: "claude-swap",
                              body: "switched to account \(current) (\(name))")
            }
            if !isPlayground {
                awake.update(wanted: keepAwake,
                             busyCount: list.liveSessions?.busy ?? 0)
            }
            applyAutoOrder()
            // Same display-feed vantage: a switch (manual or parked-engine)
            // re-arms /rc; an active account that can work resumes stopped
            // sessions. Detached, single-flight — never awaited here.
            if !isPlayground {
                let active = list.accounts.first { $0.number == list.activeAccountNumber }
                resume.tick(switched: previous != nil && previous != list.activeAccountNumber,
                            activeAlive: active.map { !AccountVitals.isDead($0.usage) } ?? false,
                            activeNumber: list.activeAccountNumber,
                            activeFetchedAt: active?.usageFetchedAt
                                .flatMap(UsageHistory.parseISO))
            }
            // Same display-feed vantage as the switch diff above: these
            // triggers fire even while the supervised engine is parked.
            let health = list.accounts
                .filter { !($0.disabled ?? false) && $0.usage != nil }
                .map { a in PushTriggers.Account(
                    number: a.number,
                    name: a.alias ?? String(a.email.prefix(while: { $0 != "@" })),
                    dead: AccountVitals.isDead(a.usage),
                    worstPct: PushTriggers.worstPlanPct(a.usage)) }
            let pushes = pushTriggers.tick(
                busy: list.liveSessions?.busy, total: list.liveSessions?.total,
                accounts: health,
                flags: .init(sessionsDone: pushSessionsDone,
                             allDead: pushAllDead, lastAlive: pushLastAlive))
            for msg in pushes where !isPlayground {
                Notifier.post(title: "claude-swap", body: msg)
                // Text over stdin, matching the channel-setup commands;
                // no channels configured is a quiet no-op (try?).
                Task { _ = try? await cli.run(["notify", "push", "-"], stdin: msg) }
            }
            if !isPlayground { await sync.tick() }
        } catch {
            // Keep the last good snapshot rather than blanking the menu —
            // same policy as the rumps menubar's _worker.
            lastError = "\(error)"
        }
    }

    /// "Did anything the popup RENDERS change?" — cheap positional
    /// comparison of the fields the rows show.
    private func accountsVisuallyEqual(_ a: [Account], _ b: [Account]) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) {
            if x.number != y.number || x.active != y.active
                || x.alias != y.alias || x.disabled != y.disabled
                || x.usage?.fiveHour?.pct != y.usage?.fiveHour?.pct
                || x.usage?.sevenDay?.pct != y.usage?.sevenDay?.pct
                || x.usage?.spend?.pct != y.usage?.spend?.pct
                || (x.usage?.scoped ?? []).map(\.pct) != (y.usage?.scoped ?? []).map(\.pct) {
                return false
            }
        }
        return true
    }

    /// The badge click: running -> stop, stopped -> start ("auto switch
    /// status is clickable to toggle", user 2026-08-30). Deliberate states
    /// only — refused/backing-off/mismatch stay informational.
    func toggleEngine() {
        switch engineState {
        case .running, .backingOff:
            let supervisor = supervisor
            self.supervisor = nil
            engineState = .stopped
            Task { await supervisor?.stop() }
        case .stopped:
            guard let cli else { return }
            startEngine(binary: cli.binaryPath)
        case .refused, .schemaMismatch:
            break
        }
    }

    /// Bounce the supervised engine — after a cswap upgrade the child is
    /// still the OLD binary until respawned.
    func restartEngine() {
        guard let cli else { return }
        let old = supervisor
        supervisor = nil
        Task {
            await old?.stop()
            await MainActor.run { self.startEngine(binary: cli.binaryPath) }
        }
    }

    func switchTo(_ number: Int) {
        guard let cli else { return }
        Task {
            do {
                try await cli.switchTo(number)
                await refreshSnapshot()
            } catch { lastError = "\(error)" }
        }
    }

    func rotate() {
        guard let cli else { return }
        Task {
            do {
                try await cli.rotate()
                await refreshSnapshot()
            } catch { lastError = "\(error)" }
        }
    }

    @Published var reorderError: String?

    /// Apply a drag-reorder: `order` is the account numbers in their new
    /// top-to-bottom sequence. Optimistically re-sorts the local rows so the
    /// row lands where it was dropped, then lets the snapshot confirm.
    /// Quit path: stop the supervised engine BEFORE the process dies, so
    /// the child never outlives the app holding the mutex (the engine also
    /// watches its stdin pipe for EOF as the backstop against a hard kill).
    func shutdown() {
        let supervisor = supervisor
        Task {
            await supervisor?.stop()
            await MainActor.run { NSApplication.shared.terminate(nil) }
        }
    }

    /// Rename = set/clear the account's cswap alias, so every frontend
    /// (TUI, CLI, popup) shows the same name.
    func rename(_ number: Int, to name: String) {
        guard let cli else { return }
        Task {
            do {
                try await cli.setAlias(number, name)
                reorderError = nil
            } catch { reorderError = "\(error)" }
            await refreshSnapshot()
        }
    }

    /// One auto-order write at a time: reorder() refreshes the snapshot,
    /// which lands back here — a no-op once the engine confirms the order.
    private var autoOrderInFlight = false

    /// Ask the engine for the policy's order when it differs from what the
    /// snapshot shows. Skipped while a switch confirmation is up: reorder
    /// renumbers occupants, and the pending number would point at a
    /// different account by the time the user hits Switch.
    func applyAutoOrder() {
        guard autoOrder, cli != nil, !autoOrderInFlight,
              pendingSwitch == nil, !accounts.isEmpty,
              dying.isEmpty else { return }
        let desired = AutoOrder.order(accounts)
        guard desired != accounts.map(\.number) else { return }
        autoOrderInFlight = true
        reorder(desired) { [weak self] in self?.autoOrderInFlight = false }
    }

    /// What the popup rows iterate: raw engine order, or the headroom
    /// sort with active + next pinned.
    var displayAccounts: [Account] {
        sortByHeadroom
            ? DisplayOrder.sort(accounts, active: activeNumber, next: nextCandidate)
            : accounts
    }

    /// Hold an account out of rotation / return it (engine-side flag;
    /// the row renders as "disabled" either way).
    func setRotation(_ number: Int, enabled: Bool) {
        guard let cli else { return }
        Task {
            do {
                _ = try await cli.setRotation(number, enabled: enabled)
                lastError = nil
            } catch { lastError = "\(error)" }
            await refreshSnapshot()
        }
    }

    func reorder(_ order: [Int], done: (() -> Void)? = nil) {
        guard let cli else { return }
        let index = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        accounts.sort { (index[$0.number] ?? 0) < (index[$1.number] ?? 0) }
        Task {
            do {
                _ = try await cli.reorder(order)
                reorderError = nil
            } catch { reorderError = "\(error)" }
            await refreshSnapshot()
            done?()
        }
    }
}

/// The shared fleet views (InfinitusUI, #9 phase B) render off this —
/// every requirement is an existing member; only the relogin action is
/// mac-only, so it lands here rather than in the protocol's no-op.
extension AppModel: FleetModel {
    func startRelogin(_ account: Account) {
        TokenFlow.shared.start(model: self, relogin: account)
    }
}
