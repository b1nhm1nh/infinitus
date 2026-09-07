import Foundation
import XCTest
@testable import InfinitusCore

/// Shared git Process helpers for Team*Tests. POSIX still shells
/// `/usr/bin/env git`; Windows uses `GitLocator` so the suites run for
/// real once git.exe is on the box, and skip on its absence.
enum TeamGitSupport {
    static func skipIfNoGit() throws {
        #if os(Windows)
        try XCTSkipIf(GitLocator.locate() == nil, "git is not installed")
        #endif
    }

    static func gitExecutable() throws -> URL {
        #if os(Windows)
        guard let git = GitLocator.locate() else {
            throw XCTSkip("git is not installed")
        }
        return URL(fileURLWithPath: git)
        #else
        return URL(fileURLWithPath: "/usr/bin/env")
        #endif
    }

    static func gitArguments(_ args: [String]) -> [String] {
        #if os(Windows)
        return args
        #else
        return ["git"] + args
        #endif
    }

    /// A bare repo standing in for the team's remote.
    static func makeRemote(in scratch: URL, name: String = "remote.git") throws -> String {
        let bare = scratch.appendingPathComponent(name)
        let p = Process()
        p.executableURL = try gitExecutable()
        p.arguments = gitArguments(["init", "--bare", "-q", bare.path])
        try p.run()
        p.waitUntilExit()
        return "file://" + bare.path
    }

    @discardableResult
    static func git(_ args: [String], stdout: Pipe? = nil,
                    stderr: FileHandle? = FileHandle.nullDevice) throws -> String {
        let p = Process()
        p.executableURL = try gitExecutable()
        p.arguments = gitArguments(args)
        let out = stdout ?? Pipe()
        p.standardOutput = out
        if let stderr { p.standardError = stderr }
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
