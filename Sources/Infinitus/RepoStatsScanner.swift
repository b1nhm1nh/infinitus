// Sources/Infinitus/RepoStatsScanner.swift
import Foundation
import InfinitusCore

/// Commits / lines / PRs from the repos Claude Code sessions worked in.
/// Cached per repo by HEAD: `git log` runs only when HEAD moved, `gh`
/// at most hourly. Author = the union of `user.email` over the repos —
/// no email to type anywhere.
actor RepoStatsScanner {
    struct Outcome: Sendable {
        var days: [String: Stats.Day] = [:]
        var repos: [String] = []
        var skipped: [String] = []       // no user.email
        var ghUsed = false
    }

    private struct RepoCache: Codable {
        var head: String
        var emails: [String]
        var days: [String: Stats.Day]
        var prsFetchedAt: Date?
        var prDays: [String: Stats.Day]
    }

    private static let dir: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Infinitus/stats/repos")
    private static let ghInterval: TimeInterval = 3600

    func scan(cwds: Set<String>, since: Date) async -> Outcome {
        var outcome = Outcome()
        var seen: Set<String> = []
        var emails: Set<String> = []
        var roots: [String] = []
        for cwd in cwds.sorted() where FileManager.default.fileExists(atPath: cwd) {
            guard let root = try? await git(["rev-parse", "--show-toplevel"], cwd: cwd)
                    .trimmingCharacters(in: .whitespacesAndNewlines), !root.isEmpty, !seen.contains(root) else { continue }
            seen.insert(root)
            roots.append(root)
            if let email = try? await git(["config", "user.email"], cwd: root)
                .trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty {
                emails.insert(email)
            }
        }
        let authors = emails.sorted()
        for root in roots {
            guard !authors.isEmpty else { outcome.skipped.append(root); continue }
            let cacheURL = Self.dir.appendingPathComponent(Self.key(root) + ".json")
            var cache = (try? Data(contentsOf: cacheURL)).flatMap { try? JSONDecoder().decode(RepoCache.self, from: $0) }
            let head = (try? await git(["rev-parse", "HEAD"], cwd: root))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if cache == nil || cache!.head != head || cache!.emails != authors {
                var args = ["log", "--all", "--no-merges", "--numstat", "--date=iso-strict",
                            "--format=\(RepoStats.logFormat)", "--since=\(ISO8601DateFormatter().string(from: since))"]
                for a in authors { args.append("--author=\(a)") }
                let text = (try? await git(args, cwd: root)) ?? ""
                let days = RepoStats.days(commits: RepoStats.parseLog(text), prs: [], repo: root)
                cache = RepoCache(head: head, emails: authors, days: days,
                                  prsFetchedAt: cache?.prsFetchedAt, prDays: cache?.prDays ?? [:])
            }
            if let ghPath = Self.ghPath,
               cache!.prsFetchedAt.map({ Date().timeIntervalSince($0) > Self.ghInterval }) ?? true,
               let json = try? await Self.run(ghPath, ["pr", "list", "--author", "@me", "--state", "all",
                                                       "--limit", "200", "--json", "number,createdAt,mergedAt"], cwd: root) {
                cache!.prDays = RepoStats.days(commits: [], prs: RepoStats.parsePRs(Data(json.utf8)), repo: root)
                cache!.prsFetchedAt = Date()
                outcome.ghUsed = true
            } else if cache!.prsFetchedAt != nil {
                outcome.ghUsed = true
            }
            try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(cache!) { try? data.write(to: cacheURL, options: .atomic) }
            outcome.repos.append(root)
            for (k, d) in cache!.days { outcome.days[k] = (outcome.days[k] ?? Stats.Day()) + d }
            for (k, d) in cache!.prDays { outcome.days[k] = (outcome.days[k] ?? Stats.Day()) + d }
        }
        return outcome
    }

    private static func key(_ root: String) -> String {
        // Stable, filesystem-safe: the path's UTF-8 as hex, capped.
        String(root.utf8.map { String(format: "%02x", $0) }.joined().suffix(120))
    }

    private static let ghPath: String? = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    private func git(_ args: [String], cwd: String) async throws -> String {
        try await Self.run("/usr/bin/git", args, cwd: cwd)
    }

    /// CswapCLI.run's shape: the blocking Process on a GCD thread, bridged
    /// by a continuation (running it inline hung on macOS 26).
    private static func run(_ exe: String, _ args: [String], cwd: String) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                p.currentDirectoryURL = URL(fileURLWithPath: cwd)
                var env = ProcessInfo.processInfo.environment
                env["GIT_OPTIONAL_LOCKS"] = "0"
                env["GH_PROMPT_DISABLED"] = "1"
                p.environment = env
                let out = Pipe()
                p.standardOutput = out
                p.standardError = Pipe()
                do { try p.run() } catch { cont.resume(throwing: error); return }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                guard p.terminationStatus == 0 else {
                    cont.resume(throwing: NSError(domain: "RepoStatsScanner", code: Int(p.terminationStatus)))
                    return
                }
                cont.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
    }
}
