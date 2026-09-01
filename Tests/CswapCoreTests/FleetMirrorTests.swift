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

    func testCloudKitFleetMirrorThrowsNotConfigured() async throws {
        do {
            _ = try await CloudKitFleetMirror().latest()
            XCTFail("expected MirrorError.notConfigured")
        } catch MirrorError.notConfigured {
            // expected
        }
    }
}
