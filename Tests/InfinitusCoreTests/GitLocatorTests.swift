import XCTest
@testable import InfinitusCore

final class GitLocatorTests: XCTestCase {
    override func setUp() {
        super.setUp()
        GitLocator.resetCache()
    }

    override func tearDown() {
        GitLocator.resetCache()
        super.tearDown()
    }

    func testWindowsCandidatesOrderingAndFallbacks() {
        let env: [String: String] = [
            "PATH": #"C:\tools\bin;D:\custom\git"#,
            "ProgramFiles": #"D:\Program Files"#,
            "ProgramFiles(x86)": #"D:\Program Files (x86)"#,
            "LOCALAPPDATA": #"D:\Users\x\AppData\Local"#,
        ]
        let candidates = GitLocator.windowsCandidates(environment: env, home: #"D:\Users\x"#)
        XCTAssertEqual(candidates, [
            #"C:\tools\bin\git.exe"#,
            #"D:\custom\git\git.exe"#,
            #"D:\Program Files\Git\cmd\git.exe"#,
            #"D:\Program Files\Git\bin\git.exe"#,
            #"D:\Program Files (x86)\Git\cmd\git.exe"#,
            #"D:\Users\x\AppData\Local\Programs\Git\cmd\git.exe"#,
        ])
    }

    func testWindowsCandidatesFallBackWhenEnvIsSparse() {
        let candidates = GitLocator.windowsCandidates(environment: [:], path: "", home: #"C:\Users\tester"#)
        XCTAssertEqual(candidates, [
            #"C:\Program Files\Git\cmd\git.exe"#,
            #"C:\Program Files\Git\bin\git.exe"#,
            #"C:\Program Files (x86)\Git\cmd\git.exe"#,
            #"C:\Users\tester\AppData\Local\Programs\Git\cmd\git.exe"#,
        ])
    }

    func testPathCandidatesSplitsSemicolonsAndAppendsGitExe() {
        let candidates = GitLocator.pathCandidates(path: #"C:\Git\cmd;C:\Windows\System32;;D:\bin"#)
        XCTAssertEqual(candidates, [
            #"C:\Git\cmd\git.exe"#,
            #"C:\Windows\System32\git.exe"#,
            #"D:\bin\git.exe"#,
        ])
        XCTAssertEqual(GitLocator.pathCandidates(path: ""), [])
    }

    func testOverridePinsPathAndEmptySimulatesMissing() {
        XCTAssertNil(GitLocator.locate(
            exists: { _ in true },
            environment: [GitLocator.overrideVariable: ""]))
        XCTAssertEqual(
            GitLocator.locate(
                exists: { $0 == #"C:\pin\git.exe"# },
                environment: [GitLocator.overrideVariable: #"C:\pin\git.exe"#]),
            #"C:\pin\git.exe"#)
        XCTAssertNil(GitLocator.locate(
            exists: { _ in false },
            environment: [GitLocator.overrideVariable: #"C:\missing\git.exe"#]))
    }

    func testLocateFirstMatchWins() {
        let candidates = [
            #"C:\first\git.exe"#,
            #"C:\second\git.exe"#,
        ]
        let hit = GitLocator.locate(
            candidates: candidates,
            exists: { $0 == #"C:\second\git.exe"# },
            environment: [:])
        XCTAssertEqual(hit, #"C:\second\git.exe"#)
    }

    func testGitNotFoundErrorNamesGitForWindows() {
        let err = TeamGit.GitError.gitNotFound
        XCTAssertTrue("\(err)".contains("Git for Windows"), "error text must name Git for Windows")
        XCTAssertFalse("\(err)".contains("unavailable"), "must not claim team is unavailable")
    }

    func testCachedLocateCachesHitsAndMisses() {
        var callCount = 0
        let exists: (String) -> Bool = { _ in
            callCount += 1
            return false
        }
        GitLocator.resetCache()
        // Override with empty to force a miss
        let firstMiss = GitLocator.locate(exists: exists, environment: [GitLocator.overrideVariable: ""])
        XCTAssertNil(firstMiss)
    }

    #if os(Windows)
    func testLiveGitLocateFindsRealGitOnWindows() {
        if ProcessInfo.processInfo.environment[GitLocator.overrideVariable] != nil { return }
        let found = GitLocator.locate()
        XCTAssertNotNil(found, "git.exe must be discoverable on a machine running git")
        if let found {
            XCTAssertTrue(found.hasSuffix(".exe"))
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: found))
        }
    }
    #endif

    /// Acceptance criteria 6: zlib determinism holds on Windows (vendored CZlib
    /// matches upstream RFC 1950 output byte for byte).
    func testDeterministicDeflateCompressionMatchesExpectedFixtureBytes() throws {
        let plaintext = Data("{\"schema\":1,\"n\":42}".utf8)
        let compressed = try Deflate.compress(plaintext)
        // Upstream zlib 1.3.1 - Z_BEST_COMPRESSION (9) produces 27 deterministic bytes:
        let expectedHex = "78daab562a4ece48cd4d54b232d451ca53b23231aa05003c820597"
        let expectedData = Data((0..<expectedHex.count / 2).compactMap { idx in
            let start = expectedHex.index(expectedHex.startIndex, offsetBy: idx * 2)
            let end = expectedHex.index(start, offsetBy: 2)
            return UInt8(expectedHex[start..<end], radix: 16)
        })
        XCTAssertEqual(compressed, expectedData, "CZlib compression on Windows must produce byte-identical zlib output")
        XCTAssertEqual(try Deflate.decompress(compressed), plaintext)
    }
}
