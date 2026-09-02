import XCTest
@testable import CswapCore

final class FleetMirrorTests: XCTestCase {
    func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("fm-\(UUID().uuidString)")
            .appendingPathComponent("mirror-snapshot.json")
    }

    func testRoundTrip() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let snapshot = MirrorSnapshot(
            capturedAt: Date(),
            machineName: "Test Mac",
            listJSON: Data("{\"accounts\":[]}".utf8),
            sessions: [SessionPanelRow(repo: "limitless", status: "busy")])
        try MirrorWriter.write(snapshot, to: url)
        let read = try await FileFleetMirror(url: url).latest()
        let got = try XCTUnwrap(read)
        XCTAssertEqual(got.machineName, snapshot.machineName)
        XCTAssertEqual(got.listJSON, snapshot.listJSON)
        XCTAssertEqual(got.sessions, snapshot.sessions)
        XCTAssertEqual(got.capturedAt.timeIntervalSince1970,
                       snapshot.capturedAt.timeIntervalSince1970, accuracy: 1)
    }

    func testRoundTripWithPrefs() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let prefs = FleetPrefs(themeID: "rpg", compactRows: true, popupLayout: "stacked",
                                burnStyle: "ash", introStyle: "fade", introTitle: "slide",
                                introSpeed: 1.5, customThemes: [.off])
        let snapshot = MirrorSnapshot(
            capturedAt: Date(),
            machineName: "Test Mac",
            listJSON: Data("{\"accounts\":[]}".utf8),
            sessions: [],
            prefs: prefs)
        try MirrorWriter.write(snapshot, to: url)
        let read = try await FileFleetMirror(url: url).latest()
        let got = try XCTUnwrap(read)
        XCTAssertEqual(got.prefs, prefs)
    }

    func testMissingPrefsDecodesToNil() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // Hand-written JSON matching a pre-#9-C1 snapshot (no "prefs" key)
        // to prove old snapshots still decode.
        let json = """
        {"capturedAt":"2026-01-01T00:00:00Z","machineName":"Old Mac",
         "listJSON":"e30=","sessions":[]}
        """
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
        let read = try await FileFleetMirror(url: url).latest()
        let got = try XCTUnwrap(read)
        XCTAssertNil(got.prefs)
    }

    func testMissingFileReturnsNil() async throws {
        let url = tempURL()
        let read = try await FileFleetMirror(url: url).latest()
        XCTAssertNil(read)
    }

    func testCorruptFileThrows() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        do {
            _ = try await FileFleetMirror(url: url).latest()
            XCTFail("expected a decode error")
        } catch {
            // corrupt content must throw, not decode to nil
        }
    }

    func testShouldWriteThrottlesToOnePerInterval() {
        let now = Date()
        XCTAssertTrue(MirrorWriter.shouldWrite(lastWrite: nil, now: now))
        XCTAssertFalse(MirrorWriter.shouldWrite(lastWrite: now, now: now.addingTimeInterval(10)))
        XCTAssertTrue(MirrorWriter.shouldWrite(lastWrite: now, now: now.addingTimeInterval(31)))
    }

    func testLinuxStateDirPrefersXDGStateHome() {
        let withXDG = MirrorWriter.linuxStateDir(
            env: ["XDG_STATE_HOME": "/custom/state"], home: "/home/test")
        XCTAssertEqual(withXDG.path, "/custom/state/infinitus")
        let fallback = MirrorWriter.linuxStateDir(env: [:], home: "/home/test")
        XCTAssertEqual(fallback.path, "/home/test/.local/state/infinitus")
    }

    func testCloudKitFleetMirrorThrowsNotConfigured() async throws {
        do {
            _ = try await CloudKitFleetMirror().latest()
            XCTFail("expected MirrorError.notConfigured")
        } catch MirrorError.notConfigured {
            // expected
        }
    }
}
