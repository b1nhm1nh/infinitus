import Foundation
import SwiftUI
import CswapCore
import InfinitusUI

/// Reads the fleet mirror a Mac already captured (#9 phase 1's
/// `FleetMirror` seam) and republishes it as view-ready state.
///
/// Conforms to `FleetModel` (#9 phase C2) so the shared popup rows —
/// the very same `AccountRows` the mac renders — draw here too. Every
/// member reproduces `AppModel`'s semantics, derived from successive
/// mirror snapshots instead of live `cswap` calls.
@MainActor
final class MirrorModel: ObservableObject, FleetModel {
    @Published private(set) var snapshot: MirrorSnapshot?
    /// Raw engine order, exactly as the snapshot listed it.
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var activeNumber: Int?
    @Published private(set) var nextRecovery: NextRecovery?
    @Published private(set) var nextCandidate: Int?
    @Published private(set) var error: String?
    /// The Mac's display prefs (#9 phase C1: "Follow Mac"); `nil` for
    /// snapshots captured before this field existed.
    @Published private(set) var prefs: FleetPrefs?

    // Animation triggers — same names, same meaning as AppModel's.
    @Published private(set) var switchFlashTick = 0
    @Published private(set) var deathTicks: [Int: Int] = [:]
    @Published private(set) var dying: Set<Int> = []
    @Published private(set) var reviveTicks: [Int: Int] = [:]
    @Published private(set) var introTick = 0
    /// Set by the view from its geometry — portrait renders the mac's
    /// stacked cards, landscape its wide grid (user's fidelity rule).
    @Published var isLandscape = false

    private let mirror: FleetMirror
    private let defaults: UserDefaults

    // MARK: display prefs — Follow Mac, or local overrides

    /// Default ON: the phone is a mirror first (#9 phase C1).
    @Published var followMac: Bool { didSet { defaults.set(followMac, forKey: "follow_mac") } }
    @Published var localThemeID: String { didSet { defaults.set(localThemeID, forKey: "gamification_style") } }
    @Published var localCompactRows: Bool { didSet { defaults.set(localCompactRows, forKey: "compact_rows") } }
    @Published var localBurnStyle: String { didSet { defaults.set(localBurnStyle, forKey: "burn_style") } }
    @Published var localIntroStyle: String { didSet { defaults.set(localIntroStyle, forKey: "intro_style") } }
    @Published var localIntroTitle: String { didSet { defaults.set(localIntroTitle, forKey: "intro_title") } }
    @Published var localIntroSpeed: Double { didSet { defaults.set(localIntroSpeed, forKey: "intro_speed") } }

    init(mirror: FleetMirror? = nil, defaults: UserDefaults = .standard) {
        self.mirror = mirror ?? Self.makeMirror()
        self.defaults = defaults
        followMac = defaults.object(forKey: "follow_mac") as? Bool ?? true
        localThemeID = defaults.string(forKey: "gamification_style") ?? "off"
        localCompactRows = defaults.object(forKey: "compact_rows") as? Bool ?? false
        localBurnStyle = defaults.string(forKey: "burn_style") ?? "ember"
        localIntroStyle = defaults.string(forKey: "intro_style") ?? "top"
        localIntroTitle = defaults.string(forKey: "intro_title") ?? "zoom"
        localIntroSpeed = defaults.object(forKey: "intro_speed") as? Double ?? 1.0
    }

    /// `INFINITUS_MIRROR_PATH` lets a simulator point at the Mac's live
    /// export; otherwise the app keeps its own copy in Documents.
    /// `fileprivate`, not `private`: `MobileUsage` below reuses it to read
    /// the same snapshot independently (#9 phase D1a).
    fileprivate static func makeMirror() -> FleetMirror {
        if let path = ProcessInfo.processInfo.environment["INFINITUS_MIRROR_PATH"] {
            return FileFleetMirror(url: URL(fileURLWithPath: path))
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return FileFleetMirror(url: documents.appendingPathComponent("mirror-snapshot.json"))
    }

    /// Pure decode of the mirror's `listJSON` payload — same `AccountList`
    /// model the mac app and tray decode, plain `JSONDecoder` (no date
    /// strategy; the model's date-bearing fields are raw ISO strings).
    static func decodeList(_ data: Data) -> AccountList? {
        try? JSONDecoder().decode(AccountList.self, from: data)
    }

    func refresh() async {
        do {
            guard let snapshot = try await mirror.latest() else {
                self.snapshot = nil
                prefs = nil
                error = nil
                return
            }
            guard let list = Self.decodeList(snapshot.listJSON) else {
                error = "couldn't read the mirrored fleet data"
                return
            }
            self.snapshot = snapshot
            prefs = snapshot.prefs
            apply(list)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// The snapshot diff, AppModel.refreshSnapshot's rules exactly: the
    /// alive/dead comparison happens BEFORE the state swap (so first load
    /// fires nothing by construction), and the swap itself is animated so
    /// the pct texts' `.contentTransition(.numericText)` rolls its digits.
    private func apply(_ list: AccountList) {
        let previousActive = activeNumber
        let firstLoad = accounts.isEmpty && !list.accounts.isEmpty
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
        withAnimation(.easeInOut(duration: 0.6)) {
            accounts = list.accounts
            activeNumber = list.activeAccountNumber
            nextCandidate = list.nextCandidate
            nextRecovery = RecoveryMath.corrected(engine: list.nextRecovery,
                                                  accounts: list.accounts)
        }
        if let now = list.activeAccountNumber, let previousActive,
           previousActive != now {
            switchFlashTick += 1
        }
        // The death sequence: the row keeps its gauges while the killing
        // drop plays, the death beat lands after the finisher, and only
        // then does the dead presentation take over.
        for n in newlyDead {
            dying.insert(n)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.3) {
                self.deathTicks[n, default: 0] += 1
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.9) {
                self.dying.remove(n)
            }
        }
        for n in newlyAlive { reviveTicks[n, default: 0] += 1 }
        if firstLoad {
            DispatchQueue.main.async { self.replayIntro() }
        }
    }

    /// Intro phase timing, AppModel's formulas: bars (and the active-row
    /// flash) hold until the content entrance has fully landed.
    var introContentDuration: Double { 0.7 / max(0.2, introSpeed) }
    var introBarDelay: Double { introContentDuration + 0.25 }

    /// The whole sequence, not just the entrances — the bars replay via
    /// the introTick environment and the flash fires after the fill.
    func replayIntro() {
        introTick += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + introBarDelay + 0.5) {
            self.switchFlashTick += 1
        }
    }

    // MARK: - FleetModel

    /// What the rows iterate: the headroom sort with active + next
    /// pinned, unless Follow Mac carries a mirrored `sortByHeadroom ==
    /// false` (#9 phase D1a). No local override exists for this pref —
    /// with Follow Mac off (or on a pre-D1a snapshot) the phone always
    /// sorts, same as before.
    var displayAccounts: [Account] {
        (macPrefs?.sortByHeadroom ?? true)
            ? DisplayOrder.sort(accounts, active: activeNumber, next: nextCandidate)
            : accounts
    }

    /// Custom skins ride in the snapshot — the phone has no themes.json.
    var availableThemes: [RowTheme] { RowTheme.builtins + (prefs?.customThemes ?? []) }
    var rowTheme: RowTheme { availableThemes.first { $0.id == themeID } ?? .off }

    /// Follow Mac supplies everything the Mac exported; with it off (or
    /// with a pre-prefs snapshot) the local overrides win.
    private var macPrefs: FleetPrefs? { followMac ? prefs : nil }
    var themeID: String { macPrefs?.themeID ?? localThemeID }
    var compactRows: Bool { macPrefs?.compactRows ?? localCompactRows }
    var burnStyle: String { macPrefs?.burnStyle ?? localBurnStyle }
    var introStyle: String { macPrefs?.introStyle ?? localIntroStyle }
    var introTitle: String { macPrefs?.introTitle ?? localIntroTitle }
    var introSpeed: Double { macPrefs?.introSpeed ?? localIntroSpeed }

    /// ORIENTATION decides the layout here, not the Mac's pref: portrait
    /// is the card UI, landscape the wide list (user's fidelity rule).
    var popupLayout: String { isLandscape ? "wide" : "stacked" }

    /// A row tap stages a switch on the mac, where an alert commits it.
    /// The phone can't drive the engine, so the staged number is dropped
    /// the moment it's set — `nil` is exactly how the mac renders while
    /// no confirmation is up.
    var pendingSwitch: Int? {
        get { nil }
        set { _ = newValue }
    }

    /// No engine to be missing: the phone reads a mirror, and "no
    /// snapshot yet" is the screen's own empty state.
    var engineMissing: Bool { false }
    var snapshotLoaded: Bool { snapshot != nil }
    /// No transparency dial on the phone — fills render at full strength.
    var fillScale: Double { 1 }
    var isPlayground: Bool { false }
}

/// The cash column's source on the phone (#9 phase D1a): the estimated-
/// spend report the mirror carries verbatim as `usageJSON`, decoded the
/// same way UsageModel's own cache read does on the mac. On-demand, not
/// tied to MirrorModel's snapshot polling — same fidelity as the mac's
/// own cash column, which is a `loadIfNeeded()` cache read too.
@MainActor
final class MobileUsage: ObservableObject, UsageSource {
    @Published private(set) var report: UsageReport?

    private let mirror: FleetMirror
    private var capturedAt: Date?

    init(mirror: FleetMirror? = nil) {
        self.mirror = mirror ?? MirrorModel.makeMirror()
    }

    func loadIfNeeded() {
        Task { await refresh() }
    }

    private func refresh() async {
        guard let snapshot = try? await mirror.latest(),
              snapshot.capturedAt != capturedAt,
              let data = snapshot.usageJSON else { return }
        capturedAt = snapshot.capturedAt
        report = try? JSONDecoder().decode(UsageReport.self, from: data)
    }
}
