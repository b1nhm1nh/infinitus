import SwiftUI
import CswapCore

/// What the fleet rows/cards read from their host's model (#9 phase B).
/// The mac app's AppModel conforms; the phone app has its own store —
/// the VIEWS stay one copy, so the popup renders pixel-identically on
/// both (that's the whole point of the shared target).
///
/// Exactly the members the moved views touch, nothing speculative: add
/// one only when a view actually reads it.
@MainActor
public protocol FleetModel: ObservableObject {
    var accounts: [Account] { get }
    /// What the rows iterate — engine order or the headroom sort.
    var displayAccounts: [Account] { get }
    var rowTheme: RowTheme { get }
    var compactRows: Bool { get }
    var burnStyle: String { get }
    var popupLayout: String { get }
    var nextCandidate: Int? { get }
    var nextRecovery: NextRecovery? { get }
    /// Limit-stopped sessions the resume nudge is holding — the all-dead
    /// banner's suffix.
    var waitingResume: Int? { get }
    /// Set by a row click; the host puts up its own confirmation.
    var pendingSwitch: Int? { get set }
    var switchFlashTick: Int { get }
    var reviveTicks: [Int: Int] { get }
    var deathTicks: [Int: Int] { get }
    var dying: Set<Int> { get }
    var fillScale: Double { get }
    var isPlayground: Bool { get }

    // Footer chips (#9 phase D2) — what FooterChips reads.
    /// Live Claude Code sessions on the host's machine (the brain chip).
    var liveSessions: LiveSessions? { get }
    /// The sessions card's presentation flag; a host that shows the card
    /// some other way (the phone renders it inline) keeps it false.
    var sessionsShown: Bool { get set }
    /// The auto-switch engine's badge state — nil on a host that has no
    /// engine reading to show.
    var engineBadge: EngineBadge? { get }
    /// Update chips: a newer build on disk / a newer release upstream.
    var appUpdatePending: Bool { get }
    var appUpdateVersion: String? { get }

    // Intro choreography (Animations.swift) — the entrance gates.
    var engineMissing: Bool { get }
    var snapshotLoaded: Bool { get }
    var introTick: Int { get }
    var introStyle: String { get }
    var introSpeed: Double { get }
    var introTitle: String { get }
    var introBarDelay: Double { get }

    /// The one row ACTION beyond pendingSwitch: relogin_required starts
    /// the host's OAuth flow (mac-only; the phone can't drive it).
    func startRelogin(_ account: Account)
    /// Footer-chip actions — all mac-only, all no-ops on a host that
    /// only mirrors (same shape as startRelogin).
    func toggleEngine()
    func relaunchApp()
    func openSettings()
}

public extension FleetModel {
    func startRelogin(_ account: Account) {}
    func toggleEngine() {}
    func relaunchApp() {}
    func openSettings() {}
    var engineBadge: EngineBadge? { nil }
    var appUpdatePending: Bool { false }
    var appUpdateVersion: String? { nil }
    /// A host with no resume nudge (the phone) simply has no count —
    /// the banner then drops its suffix.
    var waitingResume: Int? { nil }
}

/// The cash column's source — the estimated-spend report the mac app
/// scans in the background. A host without one gets empty cells.
@MainActor
public protocol UsageSource: ObservableObject {
    var report: UsageReport? { get }
    func loadIfNeeded()
}

public extension UsageSource {
    func loadIfNeeded() {}
}
