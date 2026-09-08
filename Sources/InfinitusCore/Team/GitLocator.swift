import Foundation

/// Where `git` / `git.exe` lives. Checked in order; first hit wins.
///
/// POSIX `TeamGit` still shells `/usr/bin/env git` and never calls this in
/// production. Windows cannot, so every `TeamGit` command goes through here.
/// Always compiled (pure string work) so the candidate list is unit-tested
/// on every host, like `CswapLocator`.
public enum GitLocator {
    public static let overrideVariable = "INFINITUS_GIT"

    private static let lock = NSLock()
    private enum Cache { case empty, miss, hit(String) }
    private nonisolated(unsafe) static var cache: Cache = .empty

    /// Production lookup: first hit is remembered, including a miss, so a
    /// box without git does not re-walk PATH on every publish.
    public static func cachedLocate() -> String? {
        lock.lock()
        defer { lock.unlock() }
        switch cache {
        case .hit(let path): return path
        case .miss: return nil
        case .empty:
            if let found = locate() {
                cache = .hit(found)
                return found
            }
            cache = .miss
            return nil
        }
    }

    /// Tests that pin `INFINITUS_GIT` or inject `exists:` must not leak into
    /// a later `TeamGit` command.
    public static func resetCache() {
        lock.lock()
        cache = .empty
        lock.unlock()
    }

    /// PATH walker, `.exe` only. `Process.executableURL` cannot run a
    /// `.cmd` without `cmd.exe /c` — an argv-quoting hazard, and the team
    /// token must stay out of argv. Always compiled so tests cover it on
    /// every host.
    public static func pathCandidates(path: String) -> [String] {
        var out: [String] = []
        for dir in path.split(separator: ";") where !dir.isEmpty {
            out.append("\(dir)\\git.exe")
        }
        return out
    }

    /// Windows install locations. PATH first (Git for Windows puts
    /// `git.exe` there — the common case), then both Program Files roots
    /// and the per-user install, all derived from the environment so a
    /// non-C: install and a non-`BM` profile work. `localAppData: nil` is
    /// the stripped-environment fallback.
    public static func windowsCandidates(
        environment: [String: String],
        path: String? = nil,
        home: String = NSHomeDirectory()
    ) -> [String] {
        let pathValue = path ?? environment["PATH"] ?? environment["Path"] ?? ""
        var out = pathCandidates(path: pathValue)
        let programFiles = environment["ProgramFiles"].flatMap { $0.isEmpty ? nil : $0 }
            ?? #"C:\Program Files"#
        let programFilesX86 = environment["ProgramFiles(x86)"].flatMap { $0.isEmpty ? nil : $0 }
            ?? #"C:\Program Files (x86)"#
        let local = environment["LOCALAPPDATA"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "\(home)\\AppData\\Local"
        out += [
            "\(programFiles)\\Git\\cmd\\git.exe",
            "\(programFiles)\\Git\\bin\\git.exe",
            "\(programFilesX86)\\Git\\cmd\\git.exe",
            "\(local)\\Programs\\Git\\cmd\\git.exe",
        ]
        return out
    }

    public static func defaultCandidates(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        path: String? = nil,
        home: String = NSHomeDirectory()
    ) -> [String] {
        #if os(Windows)
        return windowsCandidates(environment: environment, path: path, home: home)
        #else
        _ = (path, home, environment)
        return []
        #endif
    }

    public static func locate(
        candidates: [String]? = nil,
        exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        path: String? = nil,
        environment: [String: String]? = nil
    ) -> String? {
        let env = environment ?? ProcessInfo.processInfo.environment
        // Dev / test override: INFINITUS_GIT=/path pins the binary; the
        // empty string simulates a machine with no git.
        if candidates == nil, let forced = env[overrideVariable] {
            return forced.isEmpty ? nil : (exists(forced) ? forced : nil)
        }
        return (candidates ?? defaultCandidates(environment: env, path: path))
            .first(where: exists)
    }
}
