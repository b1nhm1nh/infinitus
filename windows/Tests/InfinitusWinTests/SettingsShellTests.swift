import XCTest
@testable import InfinitusWinUI

final class SettingsShellTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SettingsShellTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        WinSettingsStore.resetCache()
    }

    override func tearDownWithError() throws {
        WinSettingsStore.resetCache()
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    func testSettingsRoundTrip() throws {
        let file = tempDir.appendingPathComponent("settings.json")
        var s = WinSettings()
        s.showAccountName = false
        s.titlePct = "7d"
        s.titleScoped = true
        s.titleRemaining = true
        s.titleReset = "clock"
        s.titleIconOnly = true
        s.refreshIntervalSeconds = 300
        s.gamificationStyle = "rpg"
        s.pushSessionsDone = false
        s.pushAllDead = false
        s.pushLastAlive = false
        s.pushWaiting = false
        s.pushAwsLogin = false
        s.trayBalloonsEnabled = false
        s.sortByHeadroom = false
        s.mirrorPort = 12345
        s.autoResume = true
        s.lastPaneID = "accounts"
        s.windowWidth = 1024
        s.windowHeight = 768

        try WinSettingsStore.save(s, to: file)
        let loaded = WinSettingsStore.load(from: file)
        XCTAssertEqual(loaded, s)
    }

    func testMissingFileYieldsDefaults() {
        let file = tempDir.appendingPathComponent("nonexistent.json")
        let loaded = WinSettingsStore.load(from: file)
        XCTAssertEqual(loaded, WinSettings())
    }

    func testCorruptFileIsQuarantinedAndYieldsDefaults() throws {
        let file = tempDir.appendingPathComponent("settings.json")
        try "{ not json".write(to: file, atomically: true, encoding: .utf8)

        let loaded = WinSettingsStore.load(from: file)
        XCTAssertEqual(loaded, WinSettings())

        // File should not contain the corrupt data at original path
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: file.path))

        // Quarantined sibling must exist
        let contents = try fm.contentsOfDirectory(atPath: tempDir.path)
        let badFiles = contents.filter { $0.hasPrefix("settings.json.bad-") }
        XCTAssertEqual(badFiles.count, 1)
    }

    func testPartialFileKeepsKnownKeys() throws {
        let file = tempDir.appendingPathComponent("settings.json")
        let json = """
        {
            "title_pct": "5h"
        }
        """
        try json.write(to: file, atomically: true, encoding: .utf8)

        let loaded = WinSettingsStore.load(from: file)
        XCTAssertEqual(loaded.titlePct, "5h")
        XCTAssertEqual(loaded.showAccountName, true) // default
        XCTAssertEqual(loaded.refreshIntervalSeconds, 60) // default
    }

    func testUnknownKeysAreIgnored() throws {
        let file = tempDir.appendingPathComponent("settings.json")
        let json = """
        {
            "popup_layout": "compact",
            "glass_opacity": 0.8,
            "title_pct": "both"
        }
        """
        try json.write(to: file, atomically: true, encoding: .utf8)

        let loaded = WinSettingsStore.load(from: file)
        XCTAssertEqual(loaded.titlePct, "both")
        XCTAssertEqual(loaded.showAccountName, true)
    }

    func testUpdateIsLastWriterPerField() throws {
        let file = tempDir.appendingPathComponent("settings.json")
        try WinSettingsStore.update(fileURL: file) { s in
            s.titlePct = "7d"
        }
        try WinSettingsStore.update(fileURL: file) { s in
            s.gamificationStyle = "rpg"
        }

        let loaded = WinSettingsStore.load(from: file)
        XCTAssertEqual(loaded.titlePct, "7d")
        XCTAssertEqual(loaded.gamificationStyle, "rpg")
    }

    func testPaneIDBlocksDoNotOverlap() {
        var seenIDs = Set<Int32>()
        for paneIndex in 0..<14 {
            let start = PaneIDs.block(Int32(paneIndex))
            let end = start + PaneIDs.stride
            XCTAssertGreaterThanOrEqual(start, PaneIDs.base)
            for id in start..<end {
                XCTAssertFalse(seenIDs.contains(id), "Duplicate command ID \(id) in pane \(paneIndex)")
                seenIDs.insert(id)
            }
        }
    }

    func testCommandRoutingResolvesTheOwningPane() {
        let pane3ID = PaneIDs.base + 3 * PaneIDs.stride + 7
        XCTAssertEqual(PaneIDs.paneIndex(for: pane3ID), 3)

        let belowBase = PaneIDs.base - 1
        XCTAssertNil(PaneIDs.paneIndex(for: belowBase))
    }

    func testScrollClamp() {
        let res = SettingsCatalogWin.clampScroll(offset: 700, contentHeight: 1000, viewportHeight: 400)
        XCTAssertEqual(res.maxOffset, 600)
        XCTAssertEqual(res.offset, 600)

        let resNegative = SettingsCatalogWin.clampScroll(offset: -50, contentHeight: 1000, viewportHeight: 400)
        XCTAssertEqual(resNegative.offset, 0)

        let resFits = SettingsCatalogWin.clampScroll(offset: 50, contentHeight: 300, viewportHeight: 400)
        XCTAssertEqual(resFits.maxOffset, 0)
        XCTAssertEqual(resFits.offset, 0)
    }
}
