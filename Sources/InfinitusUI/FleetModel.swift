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
    /// Set by a row click; the host puts up its own confirmation.
    var pendingSwitch: Int? { get set }
    var switchFlashTick: Int { get }
    var reviveTicks: [Int: Int] { get }
    var deathTicks: [Int: Int] { get }
    var dying: Set<Int> { get }
    var fillScale: Double { get }
    var isPlayground: Bool { get }

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
}

public extension FleetModel {
    func startRelogin(_ account: Account) {}
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
