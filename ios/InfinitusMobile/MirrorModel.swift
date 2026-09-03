import Foundation
import SwiftUI
import Combine
import InfinitusCore
import InfinitusUI

/// Reads the fleet mirror a Mac already captured (#9 phase 1's
/// `FleetMirror` seam) and republishes it as view-ready state.
///
/// Coordinates one `MirrorFleetModel` per `EngineFleet` in the snapshot
/// (#9 issue 9), stable instances keyed by engineID across refreshes —
/// same split as the Mac's `EngineRegistry` / `FleetState`. Also
/// conforms to `FleetModel` itself (#9 phase C2), as a FACADE over the
/// primary (first Claude) fleet — same shape as the Mac's `AppModel` —
/// so the shared single-fleet views (header, all-dead banner, footer
/// chips) keep reading `model` directly on the "Show as Mac popup" view.
@MainActor
final class MirrorModel: ObservableObject, FleetModel {
    @Published private(set) var snapshot: MirrorSnapshot?
    /// One engine's fleet per element, in the Mac's popup order.
    @Published private(set) var fleets: [MirrorFleetModel] = []
    private var fleetSinks: [String: AnyCancellable] = [:]
    @Published private(set) var error: String?
    /// The Mac's display prefs (#9 phase C1: "Follow Mac"); `nil` for
    /// snapshots captured before this field existed.
    @Published private(set) var prefs: FleetPrefs?

    @Published private(set) var introTick = 0
    /// Set by the view from its geometry — portrait renders the mac's
    /// stacked cards, landscape its wide grid (user's fidelity rule).
    @Published var isLandscape = false

    /// The sessions card's progress feed, filled from the snapshot.
    let sessionProgress = MobileSessionProgress()

    private let mirror: FleetMirror
    private let defaults: UserDefaults
    /// Whether the LAN transport is in play (it isn't when the simulator
    /// is pointed at a file with INFINITUS_MIRROR_PATH).
    private let usesLAN: Bool

    // MARK: display prefs — Follow Mac, or local overrides

    /// Default ON: the phone is a mirror first (#9 phase C1).
    @Published var followMac: Bool { didSet { defaults.set(followMac, forKey: "follow_mac") } }
    @Published var localThemeID: String { didSet { defaults.set(localThemeID, forKey: "gamification_style") } }
    @Published var localCompactRows: Bool { didSet { defaults.set(localCompactRows, forKey: "compact_rows") } }
    @Published var localBurnStyle: String { didSet { defaults.set(localBurnStyle, forKey: "burn_style") } }
    @Published var localIntroStyle: String { didSet { defaults.set(localIntroStyle, forKey: "intro_style") } }
    @Published var localIntroTitle: String { didSet { defaults.set(localIntroTitle, forKey: "intro_title") } }
    @Published var localIntroSpeed: Double { didSet { defaults.set(localIntroSpeed, forKey: "intro_speed") } }
    /// "Show as Mac popup" (#9 native shell): the 1:1 rendering is kept,
    /// one toggle away — the native tab shell is the default.
    @Published var macPopupView: Bool { didSet { defaults.set(macPopupView, forKey: "mac_popup_view") } }

    // MARK: LAN transport (#9)

    /// Every `host:port` (or pairing-QR URL) the phone will try, in order
    /// — empty means "use Bonjour only". The mirror reads the same list
    /// straight from UserDefaults (#9 pair once, every route).
    @Published var manualEndpoints: [String] {
        didSet { defaults.set(manualEndpoints, forKey: NetworkFleetMirror.manualKey) }
    }
    /// The Mac's pairing token (#9 remote access): without it every
    /// request comes back 401, whether the Mac was found by Bonjour, by
    /// address, or through a tunnel.
    @Published var pairToken: String {
        didSet {
            // What's stored is always the normalised token, so a token
            // typed with lowercase or dashes still matches; assigning
            // back to `pairToken` re-enters `didSet` (Swift does fire it
            // for a nested assignment) and only tidies the field.
            let normalized = MirrorPairing.normalize(pairToken)
            defaults.set(normalized, forKey: NetworkFleetMirror.tokenKey)
            if normalized != pairToken { pairToken = normalized }
        }
    }
    /// What the Settings screen shows about the connection.
    @Published private(set) var transportStatus = ""

    init(mirror: FleetMirror? = nil, defaults: UserDefaults = .standard) {
        self.mirror = mirror ?? Self.makeMirror()
        self.defaults = defaults
        usesLAN = mirror == nil && ProcessInfo.processInfo
            .environment["INFINITUS_MIRROR_PATH"] == nil
        manualEndpoints = NetworkFleetMirror.storedEndpoints(defaults)
        pairToken = defaults.string(forKey: NetworkFleetMirror.tokenKey) ?? ""
        followMac = defaults.object(forKey: "follow_mac") as? Bool ?? true
        localThemeID = defaults.string(forKey: "gamification_style") ?? "off"
        localCompactRows = defaults.object(forKey: "compact_rows") as? Bool ?? false
        localBurnStyle = defaults.string(forKey: "burn_style") ?? "ember"
        localIntroStyle = defaults.string(forKey: "intro_style") ?? "top"
        localIntroTitle = defaults.string(forKey: "intro_title") ?? "zoom"
        localIntroSpeed = defaults.object(forKey: "intro_speed") as? Double ?? 1.0
        macPopupView = defaults.object(forKey: "mac_popup_view") as? Bool ?? false
    }

    /// Pairs with a Mac from a scanned QR or an `infinitus://pair?…` deep
    /// link: every route the QR carries replaces the stored list (#9 pair
    /// once, every route) — a fresh scan is meant to reset, not append —
    /// the token beside it. Returns false for anything that isn't one of
    /// our pair URLs.
    @discardableResult
    func applyPairing(_ text: String) -> Bool {
        guard let pairing = MirrorPairing.parsePairURL(text) else { return false }
        manualEndpoints = pairing.endpoints
        pairToken = pairing.token
        Task { await refresh() }
        return true
    }

    /// Adds an endpoint typed into Settings, de-duplicated — the field
    /// grows the list rather than replacing it (#9 pair once, every
    /// route: a phone paired on Wi-Fi can add a tunnel URL beside it).
    func addManualEndpoint(_ text: String) {
        let endpoint = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty, !manualEndpoints.contains(endpoint) else { return }
        manualEndpoints.append(endpoint)
    }

    func removeManualEndpoint(at offsets: IndexSet) {
        manualEndpoints.remove(atOffsets: offsets)
    }

    /// `INFINITUS_MIRROR_PATH` lets a simulator point at the Mac's live
    /// export; otherwise the LAN transport (#9) fetches the snapshot from
    /// whichever Mac advertises `_infinitus._tcp`, with the app's own
    /// Documents copy as the offline fallback.
    /// `fileprivate`, not `private`: `MobileUsage` below reuses it to read
    /// the same snapshot independently (#9 phase D1a).
    fileprivate static func makeMirror() -> FleetMirror {
        if let path = ProcessInfo.processInfo.environment["INFINITUS_MIRROR_PATH"] {
            return FileFleetMirror(url: URL(fileURLWithPath: path))
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return ChainFleetMirror(mirrors: [
            NetworkFleetMirror.shared,
            FileFleetMirror(url: documents.appendingPathComponent("mirror-snapshot.json")),
        ])
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
                fleets = []
                fleetSinks = [:]
                if usesLAN { transportStatus = await NetworkFleetMirror.shared.statusText }
                return
            }
            let engineFleets: [EngineFleet]
            if let snapshotFleets = snapshot.fleets {
                // Newer Mac: one EngineFleet per engine, already in
                // popup order — listJSON is cswap's `raw` bytes under
                // this roof, so it's never re-decoded here.
                engineFleets = snapshotFleets
            } else {
                // Older Mac: the only fleet is the legacy listJSON one,
                // wrapped as an EngineFleet so `apply` stays one path.
                guard let list = Self.decodeList(snapshot.listJSON) else {
                    error = "couldn't read the mirrored fleet data"
                    return
                }
                engineFleets = [EngineFleet(
                    engineID: MirrorFleetModel.cswapEngineID, provider: .claude,
                    accounts: list.accounts, activeNumber: list.activeAccountNumber,
                    nextCandidate: list.nextCandidate, nextRecovery: list.nextRecovery,
                    liveSessions: list.liveSessions, raw: snapshot.listJSON)]
            }
            self.snapshot = snapshot
            prefs = snapshot.prefs
            if usesLAN { transportStatus = await NetworkFleetMirror.shared.statusText }
            sessionProgress.apply(snapshot.progressByPid ?? [:])
            let firstLoad = reconcile(engineFleets)
            error = nil
            LiveActivities.shared.sync(
                fleet: fleets.first { $0.provider == .claude } ?? fleets.first,
                machine: snapshot.machineName)
            if firstLoad {
                DispatchQueue.main.async { self.replayIntro() }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Find-or-create one `MirrorFleetModel` per reported fleet — stable
    /// instances keyed by engineID across refreshes, same as the Mac's
    /// `EngineRegistry.state(for:)`, so each fleet's ticks/animations
    /// survive the next snapshot. Returns whether the PRIMARY fleet
    /// (first Claude fleet, else the first) just loaded its first
    /// snapshot — `refresh` uses that to decide whether to replay the
    /// intro, exactly as `AppModel.refreshSnapshot` does off `primary`.
    private func reconcile(_ engineFleets: [EngineFleet]) -> Bool {
        var existing = Dictionary(uniqueKeysWithValues: fleets.map { ($0.id, $0) })
        var changesByID: [String: MirrorFleetModel.Change] = [:]
        var newFleets: [MirrorFleetModel] = []
        for ef in engineFleets {
            let fleet: MirrorFleetModel
            if let found = existing.removeValue(forKey: ef.key) {
                fleet = found
            } else {
                fleet = MirrorFleetModel(engineID: ef.engineID, provider: ef.provider, host: self)
                // Delayed mutations (death/revive ticks, the switch
                // flash) land on the fleet with no coincident publish
                // here — forward them so every observer of `self`
                // (haptics, the facade) still sees them.
                fleetSinks[ef.key] = fleet.objectWillChange
                    .sink { [weak self] _ in self?.objectWillChange.send() }
            }
            changesByID[ef.key] = fleet.apply(ef)
            newFleets.append(fleet)
        }
        for goneID in existing.keys { fleetSinks.removeValue(forKey: goneID) }
        fleets = newFleets
        let primaryID = (newFleets.first { $0.provider == .claude } ?? newFleets.first)?.id
        return primaryID.flatMap { changesByID[$0] }?.firstLoad ?? false
    }

    /// The primary Claude fleet — cswap's, on a cswap machine — the
    /// facade below reads (`AppModel`'s exact rule).
    var primary: MirrorFleetModel? {
        fleets.first { $0.provider == .claude } ?? fleets.first
    }

    /// Intro phase timing, AppModel's formulas: bars (and the active-row
    /// flash) hold until the content entrance has fully landed.
    var introContentDuration: Double { 0.7 / max(0.2, introSpeed) }
    var introBarDelay: Double { introContentDuration + 0.25 }

    /// The whole sequence, not just the entrances — the bars replay via
    /// the introTick environment and the flash fires after the fill, on
    /// the PRIMARY fleet only (AppModel.replayIntro's exact rule).
    func replayIntro() {
        introTick += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + introBarDelay + 0.5) {
            self.primary?.bumpSwitchFlash()
        }
    }

    // MARK: - FleetModel (facade over the primary fleet — AppModel's shape)

    var accounts: [Account] { primary?.accounts ?? [] }
    var activeNumber: Int? { primary?.activeNumber }
    var nextCandidate: Int? { primary?.nextCandidate }
    var nextRecovery: NextRecovery? { primary?.nextRecovery }
    /// Live Claude Code sessions on the mirrored Mac — the footer's brain
    /// chip and the sessions card both read it (#9 phase D2).
    var liveSessions: LiveSessions? { primary?.liveSessions }
    var switchFlashTick: Int { primary?.switchFlashTick ?? 0 }
    var deathTicks: [Int: Int] { primary?.deathTicks ?? [:] }
    var dying: Set<Int> { primary?.dying ?? [] }
    var reviveTicks: [Int: Int] { primary?.reviveTicks ?? [:] }
    var displayAccounts: [Account] { primary?.displayAccounts ?? [] }

    /// What every fleet's `displayAccounts` sorts by (#9 phase D1a):
    /// Follow Mac's mirrored `sortByHeadroom`, else always-on. No local
    /// override exists for this pref.
    var sortByHeadroom: Bool { macPrefs?.sortByHeadroom ?? true }

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

    /// The Mac's footer chips (#9 phase D2), straight off the snapshot.
    /// The engine badge is informational here — `toggleEngine()` keeps
    /// the protocol's no-op, the phone drives no engine.
    var engineBadge: EngineBadge? { snapshot?.engine }
    var serviceStatus: ServiceStatusSummary? { snapshot?.serviceStatus }

    /// The card is rendered INLINE on the phone (the mac pops it over
    /// the brain chip), so the chip's flag never goes up — same
    /// write-it-away shape as `pendingSwitch`.
    var sessionsShown: Bool {
        get { false }
        set { _ = newValue }
    }

    /// AppModel.popupScale's mapping, for the mirrored text-size pref.
    var popupScale: CGFloat {
        switch macPrefs?.popupTextSize ?? "default" {
        case "large": return 1.15
        case "xlarge": return 1.3
        case "huge": return 1.5
        default: return 1
        }
    }

    /// No engine to be missing: the phone reads a mirror, and "no
    /// snapshot yet" is the screen's own empty state.
    var engineMissing: Bool { false }
    var snapshotLoaded: Bool { snapshot != nil }
    /// No transparency dial on the phone — fills render at full strength.
    var fillScale: Double { 1 }
    var isPlayground: Bool { false }
}

/// The sessions card's progress feed on the phone (#9 phase D2): the
/// per-pid `SessionProgress` the Mac already read from its transcripts
/// and put in the snapshot. No transcripts to read here, so `refresh`
/// keeps the protocol's no-op.
@MainActor
final class MobileSessionProgress: ObservableObject, SessionProgressSource {
    @Published private(set) var byPid: [Int: SessionProgress] = [:]

    func apply(_ byPid: [Int: SessionProgress]) {
        guard byPid != self.byPid else { return }
        self.byPid = byPid
    }
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
