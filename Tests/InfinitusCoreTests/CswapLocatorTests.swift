import XCTest
@testable import InfinitusCore

/// `CswapLocator` — Windows candidate list, LOCALAPPDATA fallback, PATH
/// `.exe` walker, `.cmd`-only = not found. POSIX `defaultCandidates` stays
/// byte-identical; the Windows list is pure string work over injected
/// `home:` / `localAppData:` / `exists:` so it runs on every host.
final class CswapLocatorTests: XCTestCase {
    func testWindowsCandidatesUseExeAndHonourLocalAppData() {
        XCTAssertEqual(
            CswapLocator.windowsCandidates(home: #"C:\Users\x"#, localAppData: #"D:\Local"#),
            [
                #"C:\Users\x\.local\bin\cswap.exe"#,
                #"D:\Local\Programs\cswap\cswap.exe"#,
                #"D:\Local\pipx\venvs\claude-swap\Scripts\cswap.exe"#,
            ])
    }

    func testWindowsCandidatesFallBackWhenLocalAppDataIsMissing() {
        XCTAssertEqual(
            CswapLocator.windowsCandidates(home: #"C:\Users\x"#, localAppData: nil),
            [
                #"C:\Users\x\.local\bin\cswap.exe"#,
                #"C:\Users\x\AppData\Local\Programs\cswap\cswap.exe"#,
                #"C:\Users\x\AppData\Local\pipx\venvs\claude-swap\Scripts\cswap.exe"#,
            ])
    }

    func testPathCandidatesAreExeOnly() {
        XCTAssertEqual(
            CswapLocator.pathCandidates(path: #"C:\py\Scripts;C:\tools"#),
            [
                #"C:\py\Scripts\cswap.exe"#,
                #"C:\tools\cswap.exe"#,
            ])
        XCTAssertEqual(CswapLocator.pathCandidates(path: ""), [])
        XCTAssertFalse(
            CswapLocator.pathCandidates(path: #"C:\py\Scripts"#)
                .contains { $0.hasSuffix(".cmd") })
    }

    func testOverrideEmptyIsNoEngineAndAPathPins() {
        XCTAssertNil(CswapLocator.locate(
            exists: { _ in true },
            environment: ["INFINITUS_CSWAP": ""]))
        XCTAssertEqual(
            CswapLocator.locate(
                exists: { $0 == #"C:\pin\cswap.exe"# },
                environment: ["INFINITUS_CSWAP": #"C:\pin\cswap.exe"#]),
            #"C:\pin\cswap.exe"#)
        XCTAssertNil(CswapLocator.locate(
            exists: { _ in false },
            environment: ["INFINITUS_CSWAP": #"C:\missing\cswap.exe"#]))
    }

    func testOverrideIsSkippedWhenCandidatesAreProvided() {
        XCTAssertEqual(
            CswapLocator.locate(
                candidates: [#"C:\explicit\cswap.exe"#],
                exists: { $0.hasSuffix("cswap.exe") },
                environment: ["INFINITUS_CSWAP": ""]),
            #"C:\explicit\cswap.exe"#)
    }

    /// Windows wheel 0.26.0 extra `unclaimedCredentials` is ignored; the
    /// existing `AccountList` decodes it with no Windows-only type.
    func testWindowsWheelListJSONDecodesOnExistingAccountList() throws {
        let json = """
        {"schemaVersion":1,"activeAccountNumber":null,"accounts":[],"unclaimedCredentials":["20260904T140847-884e64aaa671-72b70a"]}
        """
        let list = try JSONDecoder().decode(AccountList.self, from: Data(json.utf8))
        XCTAssertEqual(list.schemaVersion, 1)
        XCTAssertNil(list.activeAccountNumber)
        XCTAssertTrue(list.accounts.isEmpty)
    }

    /// Windows wheel 0.26.0 `config list --json` omits `kind`/`help`/`default`
    /// (macOS fixture has them). Existing `SettingEntry` requires those keys,
    /// so decode fails. Fix is upstream, not a forked decoder.
    func testWindowsWheelConfigJSONLacksSpecMetadata() {
        let json = """
        {"schemaVersion":1,"path":"C:\\\\Users\\\\BM\\\\.claude-swap-backup\\\\settings.json","settings":[{"key":"autoswitch.threshold","value":90.0,"isSet":false}]}
        """
        XCTAssertThrowsError(try JSONDecoder().decode(ConfigList.self, from: Data(json.utf8)))
    }

    #if os(Windows)
    func testDefaultCandidatesOnWindowsMatchTheUvList() {
        let home = #"C:\Users\x"#
        let candidates = CswapLocator.defaultCandidates(home: home)
        XCTAssertEqual(candidates.first, #"C:\Users\x\.local\bin\cswap.exe"#)
        XCTAssertTrue(candidates.allSatisfy { $0.hasSuffix(".exe") })
        XCTAssertEqual(candidates, CswapLocator.windowsCandidates(home: home))
        let local = ProcessInfo.processInfo.environment["LOCALAPPDATA"]
            ?? #"C:\Users\x\AppData\Local"#
        XCTAssertEqual(candidates[1], "\(local)\\Programs\\cswap\\cswap.exe")
        XCTAssertEqual(candidates[2], "\(local)\\pipx\\venvs\\claude-swap\\Scripts\\cswap.exe")
    }

    func testPathResolutionFindsAFixture() {
        XCTAssertEqual(
            CswapLocator.locate(
                candidates: [],
                exists: { $0 == #"C:\py\Scripts\cswap.exe"# },
                path: #"C:\py\Scripts;C:\tools"#,
                environment: [:]),
            #"C:\py\Scripts\cswap.exe"#)
    }

    func testCmdOnlyInstallResolvesToNil() {
        XCTAssertNil(CswapLocator.locate(
            candidates: [],
            exists: { $0.hasSuffix(".cmd") },
            path: #"C:\py\Scripts"#,
            environment: [:]))
        XCTAssertNil(CswapLocator.locate(
            candidates: CswapLocator.windowsCandidates(
                home: #"C:\Users\x"#, localAppData: #"D:\Local"#),
            exists: { $0.hasSuffix(".cmd") },
            path: #"C:\py\Scripts"#,
            environment: [:]))
    }

    /// Live box check: uv's `~\.local\bin\cswap.exe` is first and exists when installed.
    func testLiveLocateFindsUvInstall() throws {
        if ProcessInfo.processInfo.environment["INFINITUS_CSWAP"] != nil { return }
        let expected = "\(NSHomeDirectory())\\.local\\bin\\cswap.exe"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: expected), "cswap.exe not installed at \(expected)")
        XCTAssertEqual(
            CswapLocator.locate(environment: [:]),
            expected)
    }
    #else
    func testPosixDefaultCandidatesAreUnchanged() {
        XCTAssertEqual(CswapLocator.defaultCandidates(home: "/Users/x"), [
            "/Users/x/.local/bin/cswap",
            "/opt/homebrew/bin/cswap",
            "/usr/local/bin/cswap",
        ])
        XCTAssertNil(CswapLocator.locate(
            candidates: CswapLocator.defaultCandidates(home: "/Users/x"),
            exists: { _ in false }))
    }
    #endif
}
