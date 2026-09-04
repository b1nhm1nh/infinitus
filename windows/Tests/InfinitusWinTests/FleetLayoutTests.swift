import XCTest
import InfinitusCore

/// The account panel's CONTENT decisions. The painting needs a device
/// context and was verified by screenshot (2026-09-04); what is pinned
/// here is everything that decides WHAT gets drawn, because that is where
/// the panel could silently disagree with the Mac popup about the same
/// account.
///
/// FleetLayout lives in the tray executable, which a test host cannot
/// import (linking the executable's module kills it — see DaemonHarness),
/// so these exercise the core functions it composes. A change in either
/// that broke the panel's numbers would fail here.
final class FleetLayoutTests: XCTestCase {
    /// Bars fill by REMAINING, not used — HP semantics, so a fresh
    /// account shows a full bar and a spent one an empty bar. Getting
    /// this backwards would invert every gauge in the panel.
    func testBarsFillByRemaining() {
        XCTAssertEqual(GaugeMath.remaining(usedPct: 0), 100)
        XCTAssertEqual(GaugeMath.remaining(usedPct: 54), 46)
        XCTAssertEqual(GaugeMath.remaining(usedPct: 100), 0)
        // Over-limit clamps rather than drawing a negative-width bar.
        XCTAssertEqual(GaugeMath.remaining(usedPct: 130), 0)
    }

    /// Pace tint: warm only when the engine SAYS ahead, cool only when it
    /// says behind, nothing when it won't say. The panel draws a marker
    /// off these, so a wrong default would paint a burn on every bar.
    func testPaceTintNeedsAnExplicitVerdict() {
        XCTAssertGreaterThan(
            GaugeMath.burnHeat(usedPct: 70, expectedPct: 40, ahead: true), 0)
        XCTAssertEqual(
            GaugeMath.burnHeat(usedPct: 70, expectedPct: 40, ahead: nil), 0,
            "no verdict must not burn")
        XCTAssertEqual(
            GaugeMath.burnHeat(usedPct: 70, expectedPct: nil, ahead: true), 0,
            "no expectation must not burn")
        XCTAssertGreaterThan(
            GaugeMath.chillDepth(usedPct: 20, expectedPct: 50, ahead: false), 0)
        XCTAssertEqual(
            GaugeMath.chillDepth(usedPct: 20, expectedPct: 50, ahead: true), 0,
            "ahead of pace is never cool")
        // Both saturate at ±30 points, so a marker can't exceed the bar.
        XCTAssertEqual(GaugeMath.burnHeat(usedPct: 99, expectedPct: 1, ahead: true), 1)
        XCTAssertEqual(GaugeMath.chillDepth(usedPct: 1, expectedPct: 99, ahead: false), 1)
    }

    /// The weekly window rolls over: past its reset instant the engine's
    /// own pct is stale until the next poll, and the panel shows the
    /// rolled value like the Mac does.
    func testWeeklyRollShowsZeroAfterReset() {
        let window = UsageWindow(pct: 88, resetsAt: "2026-09-04T12:00:00Z")
        // Before its reset the engine's own number stands.
        let before = try? XCTUnwrap(WeeklyRoll.displayPct(
            window, now: WeeklyRoll.parse("2026-09-04T11:00:00Z")!))
        XCTAssertEqual(before ?? -1, 88, accuracy: 0.001)
        // After it, the stale percentage the engine still carries is
        // replaced by a fresh window.
        let after = try? XCTUnwrap(WeeklyRoll.displayPct(
            window, now: WeeklyRoll.parse("2026-09-04T13:00:00Z")!))
        XCTAssertEqual(after ?? -1, 0, accuracy: 0.001,
                       "a rolled weekly window reads as fresh, not 88%")
    }

    /// Death is what greys a row and prints its note, and it keys on ANY
    /// window being spent — including a per-model one, which is exactly
    /// the "Fable 100%" case in the screenshot.
    func testDeathDetectionCoversModelWindows() {
        let modelSpent = Usage(
            fiveHour: UsageWindow(pct: 30),
            sevenDay: UsageWindow(pct: 40),
            scoped: [UsageWindow(pct: 100, name: "Fable")])
        XCTAssertTrue(AccountVitals.isDead(modelSpent))
        XCTAssertEqual(AccountVitals.cause(modelSpent)?.kind, .scoped)
        XCTAssertEqual(AccountVitals.cause(modelSpent)?.name, "Fable")

        let healthy = Usage(fiveHour: UsageWindow(pct: 54), sevenDay: UsageWindow(pct: 20))
        XCTAssertFalse(AccountVitals.isDead(healthy))
        XCTAssertNil(AccountVitals.cause(healthy))
    }

    /// The reset caption under each bar. It must survive an engine that
    /// gave a countdown but no timestamp (and produce nothing at all when
    /// it gave neither) rather than printing a placeholder.
    func testResetCaptionDegradesGracefully() {
        XCTAssertNotNil(ResetLabel.compact(resetsAt: "2026-09-11T05:00:00Z",
                                           countdown: "6d 8h"))
        XCTAssertEqual(ResetLabel.compact(resetsAt: nil, countdown: "6d 8h"), "6d8h")
        XCTAssertNil(ResetLabel.compact(resetsAt: nil, countdown: nil))
    }
}
