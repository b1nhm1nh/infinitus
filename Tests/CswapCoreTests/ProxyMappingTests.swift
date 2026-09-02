import XCTest
@testable import CswapCore

final class ProxyMappingTests: XCTestCase {
    func fixture(_ name: String) throws -> Data {
        let url = Bundle.module.url(forResource: "Fixtures/cliproxy/\(name)", withExtension: nil)!
        return try Data(contentsOf: url)
    }

    // MARK: - Decoding

    func testAuthFileListDecodesWithUnknownKeysIgnored() throws {
        let list = try JSONDecoder().decode(ProxyAuthFileList.self, from: fixture("auth-files.json"))
        XCTAssertEqual(list.files.count, 4)
        let work = list.files[0]
        XCTAssertEqual(work.id, "auth-001")
        XCTAssertEqual(work.authIndex, "0")
        XCTAssertEqual(work.name, "claude-work@example.com")
        XCTAssertEqual(work.provider, "claude")
        XCTAssertEqual(work.priority, 5)
        XCTAssertEqual(work.note, "work")
        XCTAssertEqual(work.success, 120)
        XCTAssertEqual(work.failed, 2)
        XCTAssertEqual(work.quota?.observedAt, "2026-09-01T12:00:00Z")
        XCTAssertEqual(work.quota?.signals?["five_hour"], "ok")
        // "unexpected_future_field" on this entry must not fail decoding.
    }

    // MARK: - Grouping, ordinals, fleet order

    func testGroupingOrdinalsAndFleetOrder() throws {
        let files = try JSONDecoder().decode(ProxyAuthFileList.self, from: fixture("auth-files.json")).files
        let (fleets, ordinals) = ProxyMapping.fleets(engineID: "cliproxy", files: files, usage: [:], profiles: [:])

        XCTAssertEqual(fleets.map(\.provider), [.claude, .codex])  // gemini/other omitted when empty

        XCTAssertEqual(ordinals[.claude], [
            "claude-work@example.com", "claude-held@example.com", "claude-dead@example.com",
        ])
        XCTAssertEqual(ordinals[.codex], ["codex-main@example.com"])

        let claudeFleet = fleets.first { $0.provider == .claude }!
        XCTAssertEqual(claudeFleet.accounts.map(\.number), [1, 2, 3])
        XCTAssertEqual(claudeFleet.accounts[0].email, "claude-work@example.com")
    }

    // MARK: - Active by priority, ties

    func testActivePicksHighestPriorityLowestOrdinalOnTie() {
        let a = ProxyAuthFile(id: nil, authIndex: "0", name: "a-account", provider: "claude",
                              label: nil, status: "active", statusMessage: nil, disabled: false,
                              unavailable: false, email: "a@example.com", accountType: nil,
                              account: nil, priority: 5, note: nil, weight: nil, success: nil,
                              failed: nil, nextRetryAfter: nil, quota: nil)
        let b = ProxyAuthFile(id: nil, authIndex: "1", name: "b-account", provider: "claude",
                              label: nil, status: "active", statusMessage: nil, disabled: false,
                              unavailable: false, email: "b@example.com", accountType: nil,
                              account: nil, priority: 5, note: nil, weight: nil, success: nil,
                              failed: nil, nextRetryAfter: nil, quota: nil)
        let (fleets, _) = ProxyMapping.fleets(engineID: "cliproxy", files: [b, a], usage: [:], profiles: [:])
        let claude = fleets.first { $0.provider == .claude }!
        XCTAssertEqual(claude.activeNumber, 1)  // a-account: ordinal 1, tied priority wins on lowest ordinal
        XCTAssertTrue(claude.accounts[0].active)
        XCTAssertFalse(claude.accounts[1].active)
    }

    // MARK: - Status derivation

    func testDisabledFileIsDisabledStatus() throws {
        let files = try JSONDecoder().decode(ProxyAuthFileList.self, from: fixture("auth-files.json")).files
        let (fleets, _) = ProxyMapping.fleets(engineID: "cliproxy", files: files, usage: [:], profiles: [:])
        let held = fleets.first { $0.provider == .claude }!.accounts[1]
        XCTAssertEqual(held.disabled, true)
        XCTAssertEqual(held.usageStatus, "disabled")
        XCTAssertNil(held.alias)  // note: "" clears
    }

    func testUnavailableWithTokenMessageIsReloginRequired() throws {
        let files = try JSONDecoder().decode(ProxyAuthFileList.self, from: fixture("auth-files.json")).files
        let (fleets, _) = ProxyMapping.fleets(engineID: "cliproxy", files: files, usage: [:], profiles: [:])
        let dead = fleets.first { $0.provider == .claude }!.accounts[2]
        XCTAssertNil(dead.disabled)
        XCTAssertEqual(dead.usageStatus, "relogin_required")
    }

    func testUnavailableWithoutTokenMessageIsError() {
        let file = ProxyAuthFile(id: nil, authIndex: "0", name: "c-account", provider: "claude",
                                 label: nil, status: "error", statusMessage: nil, disabled: false,
                                 unavailable: true, email: "c@example.com", accountType: nil,
                                 account: nil, priority: 1, note: nil, weight: nil, success: nil,
                                 failed: nil, nextRetryAfter: nil, quota: nil)
        let (fleets, _) = ProxyMapping.fleets(engineID: "cliproxy", files: [file], usage: [:], profiles: [:])
        XCTAssertEqual(fleets.first!.accounts[0].usageStatus, "error")
    }

    func testNoteBecomesAlias() throws {
        let files = try JSONDecoder().decode(ProxyAuthFileList.self, from: fixture("auth-files.json")).files
        let (fleets, _) = ProxyMapping.fleets(engineID: "cliproxy", files: files, usage: [:], profiles: [:])
        let work = fleets.first { $0.provider == .claude }!.accounts[0]
        XCTAssertEqual(work.alias, "work")
    }

    // MARK: - Usage mapping

    func testUsageMappingFullFixture() throws {
        guard let usage = OAuthUsage.parse(try fixture("oauth-usage.json")) else {
            return XCTFail("expected usage")
        }
        XCTAssertEqual(usage.fiveHour?.pct, 63.2)
        XCTAssertEqual(usage.fiveHour?.resetsAt, "2026-09-02T18:00:00Z")
        XCTAssertEqual(usage.sevenDay?.pct, 91.0)
        XCTAssertEqual(usage.sevenDay?.resetsAt, "2026-09-05T00:00:00Z")
        XCTAssertEqual(usage.scoped?.first?.name, "Fable")
        XCTAssertEqual(usage.scoped?.first?.pct, 45)
        XCTAssertEqual(usage.spend?.used ?? -1, 12.34, accuracy: 0.0001)
        XCTAssertEqual(usage.spend?.limit ?? -1, 100.0, accuracy: 0.0001)
        XCTAssertEqual(usage.spend?.pct, 12.34)
        XCTAssertEqual(usage.spend?.currency, "USD")
    }

    func testUsageMappingMinimalFixture() throws {
        guard let usage = OAuthUsage.parse(try fixture("oauth-usage-minimal.json")) else {
            return XCTFail("expected usage")
        }
        XCTAssertEqual(usage.fiveHour?.pct, 40.0)
        XCTAssertNil(usage.fiveHour?.resetsAt)
        XCTAssertNil(usage.fiveHour?.countdown)
        XCTAssertNil(usage.sevenDay)
        XCTAssertNil(usage.spend)
        XCTAssertNil(usage.scoped)
    }

    // MARK: - Profile

    func testProfileParsesPlanAndOrganization() throws {
        guard let profile = ProxyProfile.parse(try fixture("oauth-profile.json")) else {
            return XCTFail("expected profile")
        }
        XCTAssertEqual(profile.organizationName, "Acme Inc")
        XCTAssertEqual(profile.organizationUuid, "org-5678")
        XCTAssertEqual(profile.plan, "Max")
    }

    // MARK: - ResetFormat, pinned against `oauth.format_reset` (TZ=UTC)

    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    func testResetFormatCountdownPinnedAgainstPython() {
        let now = date("2026-09-02T10:00:00Z")
        XCTAssertEqual(ResetFormat.countdown(until: date("2026-09-05T15:00:00Z"), now: now), "3d 5h")
        XCTAssertEqual(ResetFormat.countdown(until: date("2026-09-02T12:23:00Z"), now: now), "2h 23m")
        XCTAssertEqual(ResetFormat.countdown(until: date("2026-09-02T10:17:00Z"), now: now), "17m")
    }

    func testResetFormatClockPinnedAgainstPython() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let now = date("2026-09-02T10:00:00Z")
        XCTAssertEqual(ResetFormat.clock(date("2026-09-05T15:00:00Z"), now: now, calendar: utc), "Sep 5 15:00")
        XCTAssertEqual(ResetFormat.clock(date("2026-09-02T12:23:00Z"), now: now, calendar: utc), "12:23")
    }

    // MARK: - nextCandidate / nextRecovery

    func testNextCandidateAndRecoveryOnDeadFleet() {
        let a = ProxyAuthFile(id: nil, authIndex: "0", name: "acct-a", provider: "claude",
                              label: nil, status: "active", statusMessage: nil, disabled: false,
                              unavailable: false, email: "a@example.com", accountType: nil,
                              account: nil, priority: 1, note: nil, weight: nil, success: nil,
                              failed: nil, nextRetryAfter: nil, quota: nil)
        let b = ProxyAuthFile(id: nil, authIndex: "1", name: "acct-b", provider: "claude",
                              label: nil, status: "active", statusMessage: nil, disabled: false,
                              unavailable: false, email: "b@example.com", accountType: nil,
                              account: nil, priority: 2, note: nil, weight: nil, success: nil,
                              failed: nil, nextRetryAfter: nil, quota: nil)
        let usageA = Usage(fiveHour: UsageWindow(pct: 100, resetsAt: "2026-09-02T12:00:00Z"))
        let usageB = Usage(fiveHour: UsageWindow(pct: 100, resetsAt: "2026-09-02T15:00:00Z"))
        let (fleets, _) = ProxyMapping.fleets(engineID: "cliproxy", files: [a, b],
                                              usage: ["acct-a": usageA, "acct-b": usageB], profiles: [:])
        let claude = fleets.first { $0.provider == .claude }!
        XCTAssertEqual(claude.activeNumber, 2)  // acct-b: higher priority
        XCTAssertNil(claude.nextCandidate)      // both dead
        XCTAssertEqual(claude.nextRecovery?.number, 1)  // acct-a recovers first
        XCTAssertEqual(claude.nextRecovery?.at, "2026-09-02T12:00:00Z")
    }
}
